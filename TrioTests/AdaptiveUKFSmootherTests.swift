import Foundation
import Testing

@testable import Trio

/// Locates the TrioTests bundle for fixture loading (Swift Testing suites are structs, so a class
/// token is needed for `Bundle(for:)`).
private final class BundleToken {}

/// Golden-vector and behavior tests for `AdaptiveUKFSmoother`, the Tai port of the
/// nightscout/Trio#1302 numeric core (AAPS Boost `UnscentedKalmanFilterPlugin`).
///
/// Two golden layers, mirroring the upstream PR's gates:
/// - The **behavior vectors** are the 9 assertions the shipped AndroidAPS Kotlin unit test makes
///   (`UnscentedKalmanFilterPluginTest.kt`), same input vectors and thresholds.
/// - The **numeric fixture** (`Fixtures/ukf_python_reference.json`) was produced by the reference
///   Python `V4UKF` (the implementation the Boost benchmark scores against), recording its
///   `level_offline` — exactly the value the Swift port writes to `.smoothed`. The traces avoid
///   the compression-low regime, so they pin the numeric core (predict/update/sigma points/
///   Cholesky/RTS/adaptive-R/segmentation) with the IOB gate off. At the time this test was
///   written the port matched the fixture bit-exact (worst divergence 0.0); the 1e-6 tolerance
///   only absorbs potential compiler/stdlib floating-point differences across toolchains.
///
/// The compression-gate tests additionally cover Tai's per-reading IOB extension, which the
/// upstream fixtures deliberately do not: the same steep low is damped when IOB at the reading's
/// own time is near zero and followed when insulin on board explains it.
@Suite("Adaptive UKF Smoother Tests") struct AdaptiveUKFSmootherTests {
    // MARK: - Helpers

    private static let base: Int64 = 1_700_000_000_000

    /// Newest-first series (index 0 = most recent) at `stepMin`-minute spacing, timestamps descending.
    private func series(_ values: [Double], stepMin: Int64 = 5) -> [AdaptiveUKFGlucoseValue] {
        values.enumerated().map { i, value in
            AdaptiveUKFGlucoseValue(timestamp: Self.base - Int64(i) * stepMin * 60000, value: value)
        }
    }

    // MARK: - Python-reference golden vectors

    private struct Trace: Decodable {
        let values: [Double]
        let timestamps: [Int64]
        let level_offline: [Double]
        let rate_online: [Double]
    }

    @Test("Smoothed output matches the Python V4UKF reference on all golden traces")  func matchesGoldenVectors() throws {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "ukf_python_reference", withExtension: "json"),
            "ukf_python_reference.json must be bundled with TrioTests"
        )
        let reference = try JSONDecoder().decode([String: Trace].self, from: Data(contentsOf: url))
        #expect(reference.count >= 6, "expected the full reference set")

        let tolerance = 1E-6
        for (name, trace) in reference.sorted(by: { $0.key < $1.key }) {
            let input = zip(trace.values, trace.timestamps).map {
                AdaptiveUKFGlucoseValue(timestamp: $1, value: $0)
            }
            let out = AdaptiveUKFSmoother().smooth(input)
            #expect(out.count == trace.level_offline.count, "\(name): length mismatch")

            for i in out.indices {
                let got = try #require(out[i].smoothed, "\(name)[\(i)]: smoothed must never be nil")
                let expected = trace.level_offline[i]
                #expect(
                    abs(got - expected) <= tolerance,
                    "\(name)[\(i)]: expected \(expected), got \(got)"
                )
            }
        }
    }

    // MARK: - Kotlin behavior vectors (UnscentedKalmanFilterPluginTest.kt parity)

    @Test("Empty input returns the same empty list")  func emptyInput() {
        #expect(AdaptiveUKFSmoother().smooth([]).isEmpty)
    }

    @Test("A single value is copied to smoothed, floored at 39")  func singleValueFloored() {
        #expect(AdaptiveUKFSmoother().smooth(series([100]))[0].smoothed == 100.0)
        #expect(AdaptiveUKFSmoother().smooth(series([20]))[0].smoothed == 39.0)
    }

    @Test("Error-code 38 values collapse to the 39 floor with no valid segment")  func errorCode38Floor() {
        let out = AdaptiveUKFSmoother().smooth(series([38, 38, 38]))
        #expect(out.map(\.smoothed) == [39.0, 39.0, 39.0])
    }

    @Test("A clean series smooths every point to a sane value")  func cleanSeriesSane() throws {
        let out = AdaptiveUKFSmoother().smooth(series([101, 99, 100, 102, 98, 100, 101, 99, 100, 100]))
        #expect(out.count == 10)
        for v in out {
            let smoothed = try #require(v.smoothed)
            #expect(smoothed >= 39.0)
            #expect(abs(smoothed - 100.0) <= 30.0)
        }
    }

    @Test("A rising series produces a rising smoothed trend")  func risingTrend() throws {
        // newest-first: index 0 is the most recent (highest), last the oldest (lowest).
        let out = AdaptiveUKFSmoother().smooth(series([150, 140, 130, 120, 110, 100, 90, 80]))
        let newest = try #require(out.first?.smoothed)
        let oldest = try #require(out.last?.smoothed)
        #expect(newest > oldest)
    }

    @Test("An isolated spike is dampened toward the surrounding level")  func spikeDampened() throws {
        let out = AdaptiveUKFSmoother().smooth(series([100, 100, 100, 300, 100, 100, 100, 100]))
        let spike = out[3]
        #expect(spike.value == 300.0)
        #expect(try #require(spike.smoothed) < 200.0)
    }

    @Test("Data spanning a major gap is split into segments and both clusters are smoothed")  func majorGapSegmentation() {
        let clusterA = [100.0, 101.0, 99.0].enumerated().map { i, v in
            AdaptiveUKFGlucoseValue(timestamp: Self.base - Int64(i) * 5 * 60000, value: v)
        }
        let gapBase = Self.base - Int64(3 * 5 + 120) * 60000 // 120-min (major) gap after cluster A
        let clusterB = [120.0, 119.0, 121.0].enumerated().map { i, v in
            AdaptiveUKFGlucoseValue(timestamp: gapBase - Int64(i) * 5 * 60000, value: v)
        }
        let out = AdaptiveUKFSmoother().smooth(clusterA + clusterB)
        #expect(out.filter { $0.smoothed != nil }.count >= 4)
    }

    @Test("Smoothing is deterministic across fresh instances")  func deterministicAcrossInstances() throws {
        let a = AdaptiveUKFSmoother().smooth(series([120, 118, 122, 119, 121, 120, 118]))
        let b = AdaptiveUKFSmoother().smooth(series([120, 118, 122, 119, 121, 120, 118]))
        for i in a.indices {
            let va = try #require(a[i].smoothed)
            let vb = try #require(b[i].smoothed)
            #expect(abs(va - vb) <= 1E-9)
        }
    }

    @Test("Orphan points isolated by a gap are filled, not left nil")  func orphansFilled() throws {
        // Two leading (newest) points isolated by a 90-min gap from a 3-point segment join no
        // segment (run < 3). They must be filled with their floored raw value — never returned
        // nil — matching the reference Python V4UKF and keeping the `.smoothed` contract.
        let step: Int64 = 5 * 60000
        let readings = [
            AdaptiveUKFGlucoseValue(timestamp: Self.base, value: 105),
            AdaptiveUKFGlucoseValue(timestamp: Self.base - step, value: 103),
            AdaptiveUKFGlucoseValue(timestamp: Self.base - step - 90 * 60000, value: 120),
            AdaptiveUKFGlucoseValue(timestamp: Self.base - step - 95 * 60000, value: 119),
            AdaptiveUKFGlucoseValue(timestamp: Self.base - step - 100 * 60000, value: 121)
        ]
        let out = AdaptiveUKFSmoother().smooth(readings)
        for v in out {
            #expect(v.smoothed != nil, "every returned point must have a smoothed value")
        }
        #expect(out[0].smoothed == 105.0) // orphan → floored raw
        #expect(out[1].smoothed == 103.0)
    }

    // MARK: - Compression-low gate (per-reading IOB)

    /// Newest-first, 5-min spacing: steady ~100 then a steep fall toward 40 (a compression dip).
    /// Same trace as the upstream PR's gate test.
    private static let compressionDip: [Double] = [40, 44, 60, 82, 100, 100, 100, 100]

    @Test("A compression low with near-zero IOB is damped, not tracked to the floor")  func compressionLowIsDamped() throws {
        let damped = try #require(
            AdaptiveUKFSmoother(iobAt: { _ in 0.1 }).smooth(series(Self.compressionDip))[0].smoothed
        )
        // With real insulin on board (gate disabled) the same fall IS followed down.
        let followed = try #require(
            AdaptiveUKFSmoother(iobAt: { _ in 3.0 }).smooth(series(Self.compressionDip))[0].smoothed
        )
        #expect(damped > 52.0, "held well above the 40 floor")
        #expect(damped > followed + 5.0, "clearly higher than the un-gated case")
    }

    @Test("The gate is judged with IOB at each reading's own time, not a single spot value")  func gateUsesPerReadingIob() throws {
        // IOB low exactly during the dip readings, high before: gate active → damped.
        let dipStart = Self.base - 2 * 5 * 60000
        let damped = try #require(
            AdaptiveUKFSmoother(iobAt: { t in t >= dipStart ? 0.1 : 3.0 })
                .smooth(series(Self.compressionDip))[0].smoothed
        )
        // IOB high during the dip (insulin explains it), low before: gate off → followed.
        let followed = try #require(
            AdaptiveUKFSmoother(iobAt: { t in t >= dipStart ? 3.0 : 0.1 })
                .smooth(series(Self.compressionDip))[0].smoothed
        )
        #expect(damped > 52.0)
        #expect(damped > followed + 5.0)
    }

    @Test("Golden trace with an IOB vector per reading locks the gated smoothing output")  func matchesIobVectorGoldenTrace() throws {
        // Newest-first, 5-min spacing. Phases (newest → oldest): a dip to 40 with near-zero IOB
        // (gate damps it), a steady stretch (one reading without an IOB entry exercising the
        // fail-safe lookup), the identical dip with 3 U on board (gate off, followed down), and a
        // steady tail. Expected values were captured from the implementation after it was verified
        // bit-exact against the Python reference (gate off) and behaviorally against the upstream
        // PR's gate assertions — locking the combined core + per-reading-gate numerics against
        // regression.
        let values: [Double] = [40, 44, 60, 82, 100, 99, 100, 40, 44, 60, 82, 100, 101, 100, 100]
        let iobs: [Double?] = [0.1, 0.1, 0.1, 0.1, 0.5, nil, 0.5, 3.0, 3.0, 3.0, 3.0, 1.0, 1.0, 1.0, 1.0]
        let expected: [Double] = [
            79.930845272967,
            82.841006451117,
            85.855442143276,
            88.136485372453,
            88.641685590727,
            82.337425569492,
            69.625861183074,
            57.687995533420,
            53.407153460059,
            62.693698935060,
            77.484563549094,
            90.106004998940,
            97.595261545569,
            100.953027408397,
            102.391277583788
        ]

        var iobByTimestamp: [Int64: Double] = [:]
        var input: [AdaptiveUKFGlucoseValue] = []
        for (i, value) in values.enumerated() {
            let timestamp = Self.base - Int64(i) * 5 * 60000
            input.append(AdaptiveUKFGlucoseValue(timestamp: timestamp, value: value))
            if let iob = iobs[i] { iobByTimestamp[timestamp] = iob }
        }

        let out = AdaptiveUKFSmoother(iobAt: { iobByTimestamp[$0] ?? 99.0 }).smooth(input)
        #expect(out.count == expected.count)
        for i in out.indices {
            let got = try #require(out[i].smoothed)
            #expect(abs(got - expected[i]) <= 1E-6, "[\(i)]: expected \(expected[i]), got \(got)")
        }

        // The same raw dip reads ~22 mg/dL higher when insulin cannot explain it (index 0, gated)
        // than when it can (index 7, followed) — the discriminating property in one trace.
        let gatedDip = try #require(out[0].smoothed)
        let followedDip = try #require(out[7].smoothed)
        #expect(gatedDip > followedDip + 20.0)
    }
}
