import CoreData
import Foundation
import LoopKitUI
import Swinject
import Testing

@testable import Trio

@Suite("Glucose Smoothing Tests", .serialized) struct GlucoseSmoothingTests: Injectable {
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    var fetchGlucoseManager: BaseFetchGlucoseManager!
    var glucoseStorage: BaseGlucoseStorage!

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

        let context: NSManagedObjectContext = testContext
        glucoseStorage = BaseGlucoseStorage(resolver: resolver, contextProvider: { context })
    }

    // MARK: - Exponential Smoothing Tests

    @Test(
        "Exponential smoothing writes smoothed glucose for CGM values when enough data exists"
    ) func testExponentialSmoothingStoresSmoothedValues() async throws {
        try await deleteAllGlucose()
        let glucoseValues: [Int16] = [100, 105, 110, 115, 120, 125]
        await createGlucoseSequence(values: glucoseValues, interval: 5 * 60, isManual: false)

        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        let fetchedAscending = try await fetchAndSortGlucose()

        // We expect at least the most recent few values to get smoothed values written.
        // The Kotlin/port writes to data[i] for i in 0..<limit, where data is newest-first.
        // With 6 values:
        // - recordCount = 6
        // - validWindowCount starts at 5, no gap => remains 5
        // - smoothing produces blended.count == 5
        // - apply limit = min(5, 6) = 5 => most recent 5 entries get smoothedGlucose
        //
        // In ascending order, "most recent 5" are indices 1...5. Oldest (index 0) is not guaranteed to be updated.
        // >= not ==: the restored cgmManager can seed extra readings (see deleteAllGlucose).
        #expect(fetchedAscending.count >= 6)

        let smoothedValues = fetchedAscending.compactMap { $0.smoothedGlucose?.decimalValue }
        #expect(smoothedValues.count >= 5, "Expected at least 5 smoothed values to be stored.")

        for (i, value) in smoothedValues.enumerated() {
            #expect(value >= 39, "Smoothed glucose at index \(i) should be clamped to at least 39, got \(value).")
            #expect(
                value == value.rounded(toPlaces: 0),
                "Smoothed glucose at index \(i) should be rounded to an integer, got \(value)."
            )
        }
    }

    @Test("Exponential smoothing does not smooth manual glucose entries") func testExponentialSmoothingIgnoresManual() async throws {
        // GIVEN: Mixed manual + CGM values
        await createGlucoseSequence(values: [100, 105, 110, 115, 120].map(Int16.init), interval: 5 * 60, isManual: false)
        await createGlucose(glucose: 130, smoothed: nil, isManual: true, date: Date().addingTimeInterval(6 * 5 * 60))

        // WHEN
        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        // THEN
        let allAscending = try await fetchAndSortGlucose()
        let manual = allAscending.first(where: { $0.isManual })

        #expect(manual != nil, "Expected a manual glucose entry.")
        #expect(manual?.smoothedGlucose == nil, "Manual entries must not be smoothed/stored.")
    }

    @Test(
        "Exponential smoothing clamps smoothed glucose to >= 39 and rounds to integer"
    ) func testExponentialSmoothingClampAndRounding() async throws {
        // GIVEN
        let glucoseValues: [Int16] = [40, 39, 41, 42, 43, 44]
        await createGlucoseSequence(values: glucoseValues, interval: 5 * 60, isManual: false)

        // WHEN
        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        // THEN
        let fetchedAscending = try await fetchAndSortGlucose()

        let smoothedValues = fetchedAscending
            .compactMap { $0.smoothedGlucose?.decimalValue }
            .filter { $0 > 0 }

        #expect(!smoothedValues.isEmpty, "Expected at least one smoothed glucose value to be stored.")

        for (index, smoothed) in smoothedValues.enumerated() {
            #expect(
                smoothed >= 39,
                "Smoothed glucose must be clamped to >= 39, got \(smoothed) at index \(index)."
            )

            #expect(
                smoothed == smoothed.rounded(toPlaces: 0),
                "Smoothed glucose must be an integer value, got \(smoothed) at index \(index)."
            )
        }
    }

    @Test(
        "Exponential smoothing stops at gaps >= 12 minutes and only updates the most recent window"
    ) func testExponentialSmoothingGapStopsWindow() async throws {
        try await deleteAllGlucose()
        let now = Date()

        var dates: [Date] = []
        var values: [Int16] = []

        // Older contiguous block (should remain untouched)
        for i in 0 ..< 10 {
            dates.append(now.addingTimeInterval(Double(i) * 5 * 60))
            values.append(Int16(100 + i * 5))
        }

        // GAP (15 minutes)
        let gapStart = now.addingTimeInterval(Double(10) * 5 * 60 + 15 * 60)

        // Recent block (too small -> fallback applies only here)
        for i in 0 ..< 3 {
            dates.append(gapStart.addingTimeInterval(Double(i) * 5 * 60))
            values.append(Int16(200 + i * 5))
        }

        await createGlucoseSequence(values: values, dates: dates, isManual: false)

        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        // Assert only over the readings this test created (matched by their exact dates): the
        // restored cgmManager can asynchronously seed extra readings (see deleteAllGlucose), and
        // seeded readings outside the fetch window would fail the every-entry assertions below.
        let createdDates = Set(dates)
        let ascending = try await fetchAndSortGlucose()
            .filter { $0.date.map(createdDates.contains) ?? false }
        #expect(ascending.count == values.count)

        // After 0fa593695 "try to always smooth", the smoother sets fallback
        // smoothed = max(raw, 39) on every reading regardless of gap or window
        // size. With a 15-minute gap and only 3 readings after it, the valid
        // window (3) is below minimumWindowSize (4), so the smoother returns
        // after the fallback pass — every entry should carry a smoothed value
        // equal to its raw glucose.
        for (index, obj) in ascending.enumerated() {
            guard let smoothed = obj.smoothedGlucose?.decimalValue else {
                #expect(Bool(false), "Entry at index \(index) should have a fallback smoothedGlucose set.")
                continue
            }
            #expect(smoothed >= 39, "Smoothed glucose must be clamped to >= 39, got \(smoothed).")
            #expect(smoothed == Decimal(Int(obj.glucose)), "Fallback should equal raw glucose at index \(index).")
        }
    }

    @Test(
        "Exponential smoothing treats 38 mg/dL as xDrip error and clamps stored smoothed glucose"
    ) func testExponentialSmoothingXDrip38StopsWindow() async throws {
        try await deleteAllGlucose()
        // GIVEN
        let values: [Int16] = [100, 105, 110, 38, 120, 125]
        await createGlucoseSequence(values: values, interval: 5 * 60, isManual: false)

        // WHEN
        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        // THEN
        // >= not ==: the restored cgmManager can seed extra readings (see deleteAllGlucose).
        let ascending = try await fetchAndSortGlucose()
        #expect(ascending.count >= 6)

        let smoothedValues = ascending
            .compactMap { $0.smoothedGlucose?.decimalValue }
            .filter { $0 > 0 }

        #expect(
            !smoothedValues.isEmpty,
            "Expected at least one smoothed glucose value to be stored."
        )

        for (index, smoothed) in smoothedValues.enumerated() {
            #expect(
                smoothed >= 39,
                "Smoothed glucose must be clamped to >= 39 even around xDrip 38, got \(smoothed) at index \(index)."
            )
            #expect(
                smoothed == smoothed.rounded(toPlaces: 0),
                "Smoothed glucose must be rounded to an integer, got \(smoothed) at index \(index)."
            )
        }
    }

    // MARK: - fetchGlucose Window Tests

    @Test(
        "fetchGlucose retains the most recent readings (not the oldest) when the window holds more than the fetch limit"
    ) func testFetchGlucoseKeepsMostRecentWhenOverLimit() async throws {
        // GIVEN: 400 readings within the last 24h (3 min spacing => 20h span) — more than the
        // fetch limit, which scales with the window (hours * 15, i.e. 360 for the default 24h).
        // Each reading carries a unique glucose value so we can verify which subset survives the limit.
        let count = 400
        let limit = 360
        let values: [Int16] = (0 ..< count).map { Int16(100 + $0) }
        await createGlucoseSequence(values: values, interval: 3 * 60, isManual: false)

        // WHEN
        let objectIDs = try await fetchGlucoseManager.fetchGlucose(context: testContext)

        // THEN
        #expect(objectIDs.count == limit, "fetchGlucose should respect the \(limit) limit, got \(objectIDs.count).")

        await testContext.perform {
            let fetched = objectIDs.compactMap { self.testContext.object(with: $0) as? GlucoseStored }
            #expect(fetched.count == limit, "All returned object IDs must resolve to GlucoseStored instances.")

            // Returned order must be oldest-first (chronological) — the smoother walks the array this way.
            let dates = fetched.compactMap(\.date)
            #expect(dates == dates.sorted(), "fetchGlucose must return readings in chronological (ascending) order.")

            // The most recent reading (current BG) must be the LAST element after the chronological reverse.
            #expect(
                fetched.last?.glucose == Int16(100 + count - 1),
                "Most recent reading (current BG) must be retained after the fetch-limit truncation."
            )

            // The oldest 40 readings must be dropped — verify the limit cut from the OLD end, not the recent end.
            let returnedGlucoseValues = Set(fetched.map(\.glucose))
            #expect(
                !returnedGlucoseValues.contains(Int16(100)),
                "Oldest reading must be excluded by the limit (truncation should cut old, not recent)."
            )
            #expect(
                returnedGlucoseValues.contains(Int16(100 + count - 1)),
                "Newest reading must be included after truncation."
            )
        }
    }

    @Test(
        "Exponential smoothing writes a smoothed value for the current BG when 24h holds more readings than the fetch limit"
    ) func testExponentialSmoothingCoversCurrentBGAboveLimit() async throws {
        try await deleteAllGlucose()
        // GIVEN: 360 contiguous CGM readings within the last 24h (3 min spacing, no gaps).
        let count = 360
        let values: [Int16] = (0 ..< count).map { _ in Int16(120) }
        await createGlucoseSequence(values: values, interval: 3 * 60, isManual: false)

        // WHEN
        await fetchGlucoseManager.exponentialSmoothingGlucose(context: testContext)

        // THEN: the most recent reading must have received a smoothed value.
        // Regression test for the bug where ascending+fetchLimit kept the OLDEST readings,
        // so the current BG fell outside the smoothing window and was never written.
        // No exact-count assertion: the restored cgmManager can asynchronously seed extra
        // readings (see deleteAllGlucose), but our created readings are future-dated, so the
        // newest reading — the one this regression test is about — is always ours.
        let ascending = try await fetchAndSortGlucose()
        #expect(ascending.count >= count)

        #expect(
            ascending.last?.smoothedGlucose != nil,
            "Most recent reading (current BG) must receive a smoothed value when over the fetch limit."
        )
    }

    // MARK: - Adaptive UKF Smoothing Tests (integration, mirroring nightscout/Trio#1302)

    @Test(
        "Adaptive UKF smoothing writes smoothed glucose for CGM values when enough data exists"
    ) func testAdaptiveSmoothingStoresSmoothedValues() async throws {
        try await deleteAllGlucose()
        // Deliberately noisy so the filter visibly departs from raw somewhere.
        let glucoseValues: [Int16] = [100, 132, 94, 136, 90, 140, 92, 138, 96, 134]
        let dates = await createGlucoseSequence(values: glucoseValues, interval: 5 * 60, isManual: false)

        await fetchGlucoseManager.adaptiveUkfSmoothingGlucose(context: testContext)

        let createdDates = Set(dates)
        let ours = try await fetchAndSortGlucose()
            .filter { $0.date.map(createdDates.contains) ?? false }
        #expect(ours.count == glucoseValues.count)

        for (index, object) in ours.enumerated() {
            let smoothed = try #require(
                object.smoothedGlucose?.decimalValue,
                "Every reading must receive a smoothed value, missing at index \(index)."
            )
            #expect(smoothed >= 39, "Smoothed glucose must be clamped to >= 39, got \(smoothed).")
            #expect(
                smoothed == smoothed.rounded(toPlaces: 0),
                "Smoothed glucose must be stored as integer mg/dL, got \(smoothed)."
            )
        }
    }

    @Test("Adaptive UKF smoothing does not smooth manual glucose entries") func testAdaptiveSmoothingIgnoresManual() async throws {
        await createGlucoseSequence(values: [100, 105, 110, 115, 120].map(Int16.init), interval: 5 * 60, isManual: false)
        await createGlucose(glucose: 130, smoothed: nil, isManual: true, date: Date().addingTimeInterval(6 * 5 * 60))

        await fetchGlucoseManager.adaptiveUkfSmoothingGlucose(context: testContext)

        let manual = try await fetchAndSortGlucose().first(where: \.isManual)
        #expect(manual != nil, "Expected a manual glucose entry.")
        #expect(manual?.smoothedGlucose == nil, "Manual entries must not be smoothed/stored.")
    }

    @Test(
        "Adaptive UKF smoothing clamps smoothed glucose to >= 39 and stores integers"
    ) func testAdaptiveSmoothingClampAndRounding() async throws {
        try await deleteAllGlucose()
        let glucoseValues: [Int16] = [40, 39, 41, 42, 43, 44]
        let dates = await createGlucoseSequence(values: glucoseValues, interval: 5 * 60, isManual: false)

        await fetchGlucoseManager.adaptiveUkfSmoothingGlucose(context: testContext)

        let createdDates = Set(dates)
        let smoothedValues = try await fetchAndSortGlucose()
            .filter { $0.date.map(createdDates.contains) ?? false }
            .compactMap { $0.smoothedGlucose?.decimalValue }

        #expect(!smoothedValues.isEmpty, "Expected smoothed glucose values to be stored.")
        for (index, smoothed) in smoothedValues.enumerated() {
            #expect(smoothed >= 39, "Smoothed glucose must be clamped to >= 39, got \(smoothed) at index \(index).")
            #expect(
                smoothed == smoothed.rounded(toPlaces: 0),
                "Smoothed glucose must be an integer value, got \(smoothed) at index \(index)."
            )
        }
    }

    // MARK: - OpenAPS Glucose Selection Tests

    @Test("Algorithm uses smoothed glucose when enabled") func testAlgorithmUsesSmoothedGlucose() async throws {
        await createGlucose(glucose: 150, smoothed: 140, isManual: false, date: Date())

        let algorithmInput = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 24)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.sgv == 140,
            "Algorithm should have used the smoothed glucose value (140), but used \(algorithmInput.first?.sgv ?? 0)."
        )
    }

    @Test("Algorithm uses raw glucose when smoothing is disabled") func testAlgorithmUsesRawGlucose() async throws {
        await createGlucose(glucose: 150, smoothed: 140, isManual: false, date: Date())

        let algorithmInput = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 24)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.sgv == 150,
            "Algorithm should have used the raw glucose value (150), but used \(algorithmInput.first?.sgv ?? 0)."
        )
    }

    @Test("Algorithm falls back to raw glucose if smoothed value is missing") func testAlgorithmFallbackToRawGlucose() async throws {
        await createGlucose(glucose: 150, smoothed: nil, isManual: false, date: Date())

        let algorithmInput = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 24)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.sgv == 150,
            "Algorithm should have fallen back to the raw glucose value (150), but used \(algorithmInput.first?.sgv ?? 0)."
        )
    }

    @Test("Algorithm ignores smoothed value for manual glucose entries") func testAlgorithmIgnoresSmoothedManualGlucose() async throws {
        await createGlucose(glucose: 150, smoothed: 140, isManual: true, date: Date())

        let algorithmInput = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 24)

        #expect(algorithmInput.count == 1, "Expected to process one glucose entry.")
        #expect(
            algorithmInput.first?.glucose == 150,
            "Algorithm should have ignored smoothing for a manual entry and used the raw value (150), but used \(algorithmInput.first?.glucose ?? 0)."
        )
    }

    // MARK: - Helpers

    private func createGlucose(glucose: Int16, smoothed: Decimal?, isManual: Bool, date: Date) async {
        await testContext.perform {
            let object = GlucoseStored(context: self.testContext)
            object.date = date
            object.glucose = glucose
            object.smoothedGlucose = smoothed as NSDecimalNumber?
            object.isManual = isManual
            object.id = UUID()
            try! self.testContext.save()
        }
    }

    private func createGlucoseSequence(values: [Int16], dates: [Date], isManual: Bool) async {
        precondition(values.count == dates.count)

        await testContext.perform {
            for (i, value) in values.enumerated() {
                let object = GlucoseStored(context: self.testContext)
                object.date = dates[i]
                object.glucose = value
                object.smoothedGlucose = nil
                object.isManual = isManual
                object.id = UUID()
            }
            try! self.testContext.save()
        }
    }

    @discardableResult private func createGlucoseSequence(
        values: [Int16],
        interval: TimeInterval,
        isManual: Bool
    ) async -> [Date] {
        let now = Date()
        let dates = values.indices.map { now.addingTimeInterval(Double($0) * interval) }
        await createGlucoseSequence(values: values, dates: dates, isManual: isManual)
        return dates
    }

    /// Removes any pre-existing GlucoseStored rows. State can leak between tests
    /// in this suite (Swift Testing reuses suite instances in `.serialized` runs
    /// even though `init()` reassigns the stack), and `BaseFetchGlucoseManager.init`
    /// may seed a reading via the restored cgmManager. Call at the start of any
    /// test that asserts on the total fetched count.
    private func deleteAllGlucose() async throws {
        try await testContext.perform {
            let request: NSFetchRequest<NSFetchRequestResult> = GlucoseStored.fetchRequest()
            let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
            batchDelete.resultType = .resultTypeObjectIDs
            let result = try self.testContext.execute(batchDelete) as? NSBatchDeleteResult
            if let ids = result?.result as? [NSManagedObjectID], !ids.isEmpty {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                    into: [self.testContext]
                )
            }
            self.testContext.reset()
        }
    }

    private func fetchAndSortGlucose() async throws -> [GlucoseStored] {
        try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: .all,
            key: "date",
            ascending: true
        ) as? [GlucoseStored] ?? []
    }
}
