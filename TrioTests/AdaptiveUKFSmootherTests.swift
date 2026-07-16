import Foundation
import Testing

@testable import Trio

/// Golden-vector and behavior tests for `AdaptiveUKFSmoother`, the Tai port of the
/// nightscout/Trio#1302 numeric core (AAPS Boost `UnscentedKalmanFilterPlugin`).
///
/// The golden fixture is the PR's own `ukf_python_reference.json`: each trace was produced by the
/// reference Python `V4UKF` implementation (the one the Boost benchmark scores against), recording
/// its `level_offline` — exactly the value the Swift port writes to `.smoothed`. The traces avoid
/// the compression-low regime, so they exercise the shared numeric core (predict/update/sigma
/// points/Cholesky/RTS/adaptive-R/segmentation) with the IOB gate off. At the time this test was
/// written the port matched the fixture bit-exact (worst divergence 0.0); the 1e-6 tolerance only
/// absorbs potential compiler/stdlib floating-point differences across toolchains.
///
/// The compression-gate tests cover Tai's per-reading IOB extension, which the fixture deliberately
/// does not: the same steep low is damped when IOB at the reading's time is near zero and followed
/// when insulin on board explains it.
@Suite("Adaptive UKF Smoother Tests") struct AdaptiveUKFSmootherTests {
    // MARK: - Golden vectors

    private struct Trace: Decodable {
        let values: [Double]
        let timestamps: [Int64]
        let level_offline: [Double]
        let rate_online: [Double]
    }

    @Test("Smoothed output matches the Python V4UKF reference on all golden traces") func matchesGoldenVectors() throws {
        let reference = try JSONDecoder().decode(
            [String: Trace].self,
            from: Data(Self.pythonReferenceFixture.utf8)
        )
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

    // MARK: - Compression-low gate (per-reading IOB)

    /// Newest-first, 5-min spacing: steady ~100 then a steep fall toward 40 (a compression dip).
    /// Same trace as the upstream PR's gate test.
    private static let compressionDip: [Double] = [40, 44, 60, 82, 100, 100, 100, 100]
    private static let base: Int64 = 1_700_000_000_000

    private func series(_ values: [Double]) -> [AdaptiveUKFGlucoseValue] {
        values.enumerated().map { i, value in
            AdaptiveUKFGlucoseValue(timestamp: Self.base - Int64(i) * 5 * 60000, value: value)
        }
    }

    @Test("A compression low with near-zero IOB is damped, not tracked to the floor") func compressionLowIsDamped() throws {
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

    @Test("The gate is judged with IOB at each reading's own time, not a single spot value") func gateUsesPerReadingIob() throws {
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

    // MARK: - Fixture

    /// Verbatim copy of `GlucoseSmoothing/Tests/GlucoseSmoothingCoreTests/Fixtures/
    /// ukf_python_reference.json` from nightscout/Trio#1302 (generated by `generate_reference.py`
    /// running the reference Python `V4UKF`). Embedded so the test needs no resource bundle.
    private static let pythonReferenceFixture = #"""
    {
     "clean10": {
      "values": [
       101.0,
       99.0,
       100.0,
       102.0,
       98.0,
       100.0,
       101.0,
       99.0,
       100.0,
       100.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699999100000,
       1699998800000,
       1699998500000,
       1699998200000,
       1699997900000,
       1699997600000,
       1699997300000
      ],
      "level_offline": [
       100.37702324573459,
       100.1166664918794,
       100.11586334865052,
       100.12988058469533,
       99.8269546488569,
       99.86915237814357,
       99.9445177194831,
       99.83759287481509,
       99.87814530942889,
       99.93869017492241
      ],
      "rate_online": [
       0.03985873931789399,
       -0.05809080509616013,
       0.025526783140246777,
       0.10164989777443148,
       -0.10438373272083382,
       0.015330469434316363,
       0.054881338860503226,
       -0.060937657460616586,
       -5.745303312952426e-14,
       0.0
      ]
     },
     "rising8": {
      "values": [
       150.0,
       140.0,
       130.0,
       120.0,
       110.0,
       100.0,
       90.0,
       80.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699999100000,
       1699998800000,
       1699998500000,
       1699998200000,
       1699997900000
      ],
      "level_offline": [
       148.39518359382677,
       139.84295359454666,
       130.40860108235682,
       120.58252981805916,
       110.65916667164339,
       100.68482708557784,
       90.42908435334145,
       79.35849843241432
      ],
      "rate_online": [
       1.436993698213369,
       1.4266324704055182,
       1.4159783579932117,
       1.4161900151411775,
       1.4460212565609663,
       1.5266130617729656,
       1.6929634497811816,
       2.0
      ]
     },
     "spike8": {
      "values": [
       100.0,
       100.0,
       100.0,
       300.0,
       100.0,
       100.0,
       100.0,
       100.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699999100000,
       1699998800000,
       1699998500000,
       1699998200000,
       1699997900000
      ],
      "level_offline": [
       104.53745023150964,
       114.72437137134676,
       121.66105791992997,
       124.65497905900331,
       116.15982127852273,
       107.79806098136626,
       102.06944067784228,
       98.41934394774339
      ],
      "rate_online": [
       -1.6661869166377004,
       -0.28919689695332895,
       1.5049458437248462,
       4.0,
       -3.728903988675025e-14,
       -1.596947662809851e-13,
       -5.745303312952426e-14,
       0.0
      ]
     },
     "det7": {
      "values": [
       120.0,
       118.0,
       122.0,
       119.0,
       121.0,
       120.0,
       118.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699999100000,
       1699998800000,
       1699998500000,
       1699998200000
      ],
      "level_offline": [
       119.58886165422452,
       119.77740633076178,
       120.2442202677834,
       120.29453230906454,
       120.21324334011571,
       119.53962622261452,
       118.21895032027936
      ],
      "rate_online": [
       -0.0347040933714867,
       -0.11035797503147826,
       0.10728347529305189,
       0.021772289004926004,
       0.24438495489398462,
       0.338592689956186,
       0.4
      ]
     },
     "noisy30": {
      "values": [
       124.0,
       126.9,
       143.6,
       140.4,
       148.3,
       135.5,
       134.7,
       115.8,
       112.9,
       96.3,
       99.6,
       91.7,
       104.7,
       105.5,
       124.4,
       127.3,
       143.8,
       140.5,
       148.2,
       135.2,
       134.3,
       115.4,
       112.6,
       96.0,
       99.5,
       91.8,
       105.0,
       105.9,
       124.8,
       127.6
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699999100000,
       1699998800000,
       1699998500000,
       1699998200000,
       1699997900000,
       1699997600000,
       1699997300000,
       1699997000000,
       1699996700000,
       1699996400000,
       1699996100000,
       1699995800000,
       1699995500000,
       1699995200000,
       1699994900000,
       1699994600000,
       1699994300000,
       1699994000000,
       1699993700000,
       1699993400000,
       1699993100000,
       1699992800000,
       1699992500000,
       1699992200000,
       1699991900000,
       1699991600000,
       1699991300000
      ],
      "level_offline": [
       127.75012317961689,
       132.75781412303868,
       137.8684804956834,
       140.6417216011411,
       140.43554959233668,
       136.11243572443408,
       128.90053206891844,
       119.38727063830451,
       110.2078851232274,
       102.4978642363905,
       98.58022299834784,
       98.46685545326828,
       103.0771431888844,
       110.68149469270405,
       120.70167948358336,
       130.19769091818654,
       138.12541308586242,
       141.9870451417714,
       142.019766908416,
       137.15285275825403,
       129.37343707580263,
       119.17743102232065,
       109.65930198750958,
       101.77659336024996,
       98.03300931287463,
       98.04131607689986,
       102.72501559671781,
       109.90121228474973,
       118.99129228669304,
       127.16762176270012
      ],
      "rate_online": [
       -0.8326732357227995,
       -0.5421523679413498,
       0.34236001178011444,
       0.6563423740968658,
       1.3782979523561831,
       1.3083986507097642,
       1.5304385901593174,
       0.8887210134661567,
       0.599830699831629,
       -0.29896158715766025,
       -0.6033734064616874,
       -1.405218166358949,
       -1.32516000308744,
       -1.6174747336823008,
       -0.9435912610493946,
       -0.6573872444623485,
       0.2630413080180293,
       0.5518524559919431,
       1.4238810567272089,
       1.3255038955477647,
       1.6510335330895147,
       0.9468496294578018,
       0.6592623750818105,
       -0.27217338537406777,
       -0.5276198695520901,
       -1.3419875824612184,
       -1.1489785670785593,
       -1.408547942409639,
       -0.4740297659386383,
       -0.5599999999999994
      ]
     },
     "gap6": {
      "values": [
       100.0,
       101.0,
       99.0,
       120.0,
       119.0,
       121.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699999400000,
       1699991900000,
       1699991600000,
       1699991300000
      ],
      "level_offline": [
       100.86933240639375,
       100.18046550835606,
       98.9681293345607,
       119.1306675936061,
       119.81953449164517,
       121.0318706654389
      ],
      "rate_online": [
       0.12250963997318168,
       0.338592689956186,
       0.4,
       -0.12250963997316411,
       -0.33859268995630093,
       -0.4
      ]
     },
     "orphan5": {
      "values": [
       105.0,
       103.0,
       120.0,
       119.0,
       121.0
      ],
      "timestamps": [
       1700000000000,
       1699999700000,
       1699994300000,
       1699994000000,
       1699993700000
      ],
      "level_offline": [
       105.0,
       103.0,
       119.1306675936061,
       119.81953449164517,
       121.0318706654389
      ],
      "rate_online": [
       0.0,
       0.0,
       -0.12250963997316411,
       -0.33859268995630093,
       -0.4
      ]
     }
    }
    """#
}
