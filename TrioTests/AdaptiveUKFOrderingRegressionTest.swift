import CoreData
import Foundation
import LoopKitUI
import Swinject
import Testing

@testable import Trio

/// Regression guard for the Adaptive UKF glucose-smoother ORDER bug (ported from the
/// nightscout/Trio#1302 `UkfOrderingRegressionTest`, which caught this on live data).
///
/// `fetchGlucose` returns readings **oldest-first** (it fetches date-descending for the limit, then
/// reverses). `AdaptiveUKFSmoother.smooth` requires **newest-first** — fed oldest-first its
/// segmentation sees negative time-diffs, forms no segment, and copies raw, so the filter goes
/// inert. `adaptiveUkfSmoothingGlucose` must therefore reverse before feeding the core.
///
/// This test drives the production method end-to-end (Core Data fetch → reverse → smooth → store)
/// and asserts (a) the filter actually smooths (departs from raw) and (b) the stored values match
/// an independent newest-first run of the core. If the reversal is ever removed, both fail.
@Suite("Adaptive UKF ordering regression", .serialized) struct AdaptiveUKFOrderingRegressionTest: Injectable {
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var fetchGlucoseManager: BaseFetchGlucoseManager!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)

        fetchGlucoseManager = resolver.resolve(FetchGlucoseManager.self)! as? BaseFetchGlucoseManager
    }

    @Test(
        "adaptiveUkfSmoothingGlucose feeds the core newest-first (guards the oldest-first order bug)"
    ) func adaptiveSmoothingReceivesNewestFirst() async throws {
        // A deliberately noisy series so a working filter visibly departs from raw. Built
        // OLDEST-first (index 0 = oldest), 5-min spacing, ending now — inside the fetch window.
        let sgvs: [Int16] = [100, 132, 94, 136, 90, 140, 92, 138, 96, 134, 98, 130, 101, 128, 103]
        let newestDate = Date()
        let dates = sgvs.indices.map { newestDate.addingTimeInterval(-Double(sgvs.count - 1 - $0) * 300) }

        try await testContext.perform {
            for (i, value) in sgvs.enumerated() {
                let object = GlucoseStored(context: self.testContext)
                object.date = dates[i]
                object.glucose = value
                object.smoothedGlucose = nil
                object.isManual = false
                object.id = UUID()
            }
            try self.testContext.save()
        }

        // Production path: fetch (oldest-first), reverse, smooth, store.
        await fetchGlucoseManager.adaptiveUkfSmoothingGlucose(context: testContext)

        // Oracle over the SAME input set the production method smooths — the production fetch
        // (oldest-first, non-manual, 24h) — because the restored cgmManager can seed extra
        // readings that join the smoothing window and influence neighboring values.
        let objectIDs = try await fetchGlucoseManager.fetchGlucose(context: testContext)
        let createdDates = Set(dates)
        let (storedOldestFirst, oracleOldestFirst, isOurs): ([Double], [Double], [Bool]) =
            try await testContext.perform {
                let fetched = objectIDs.compactMap { self.testContext.object(with: $0) as? GlucoseStored }
                let ours = fetched.filter { $0.date.map(createdDates.contains) ?? false }
                #expect(ours.count == sgvs.count, "all created readings must be part of the fetch window")

                let stored = fetched.map { $0.smoothedGlucose?.doubleValue ?? -1 } // oldest-first

                // Oracle: feed the core newest-first directly, then map back to oldest-first with
                // the same round-to-integer + 39 floor the production method applies on storage.
                let newestFirst: [AdaptiveUKFGlucoseValue] = fetched.reversed().map {
                    AdaptiveUKFGlucoseValue(
                        timestamp: Int64(($0.date ?? Date()).timeIntervalSince1970 * 1000),
                        value: Double($0.glucose)
                    )
                }
                let out = AdaptiveUKFSmoother().smooth(newestFirst)
                let n = fetched.count
                var oracle = [Double](repeating: -1, count: n)
                for k in out.indices {
                    let smoothed = out[k].smoothed ?? max(out[k].value, 39.0)
                    oracle[n - 1 - k] = Double(Int(smoothed.rounded())) // out[k] ↔ fetched[n-1-k]
                }
                let mine = fetched.map { $0.date.map(createdDates.contains) ?? false }
                return (stored, oracle, mine)
            }

        // (a) Smoothing actually happened on our noisy readings. Fed backwards, every stored value
        // equals raw and this is 0.
        var departures = 0
        var oursSeen = 0
        var sgvIndex = 0
        for (i, stored) in storedOldestFirst.enumerated() where isOurs[i] {
            oursSeen += 1
            if abs(stored - Double(sgvs[sgvIndex])) > 2.0 { departures += 1 }
            sgvIndex += 1
        }
        #expect(oursSeen == sgvs.count)
        #expect(
            departures >= sgvs.count / 2,
            "filter barely departed from raw (\(departures)/\(sgvs.count)) — likely fed oldest-first (order bug)"
        )

        // (b) Stored values match the newest-first oracle (± rounding) across the whole window.
        for (i, (stored, oracle)) in zip(storedOldestFirst, oracleOldestFirst).enumerated() {
            #expect(
                abs(stored - oracle) <= 1.0,
                "reading \(i): stored \(stored) but newest-first core gives \(oracle) — ordering mismatch"
            )
        }
    }
}
