import Foundation
import Testing

@testable import Trio

@Suite("Multi-Use Panel State Tests") struct MultiUsePanelStateTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var fresh: Date { now.addingTimeInterval(-5 * 60) }
    private var stale: Date { now.addingTimeInterval(-20 * 60) }

    private func resolve(
        bolusInProgress: Bool = false,
        notificationsDisabled: Bool = false,
        pumpTimeMismatch: Bool = false,
        lastGlucoseDate: Date?,
        maxIOB: Decimal = 10,
        hasOverride: Bool = false,
        hasTempTarget: Bool = false,
        hasTempProfile: Bool = false
    ) -> MultiUsePanelState {
        MultiUsePanelState.resolve(
            bolusInProgress: bolusInProgress,
            notificationsDisabled: notificationsDisabled,
            pumpTimeMismatch: pumpTimeMismatch,
            lastGlucoseDate: lastGlucoseDate,
            maxIOB: maxIOB,
            hasOverride: hasOverride,
            hasTempTarget: hasTempTarget,
            hasTempProfile: hasTempProfile,
            now: now
        )
    }

    @Test("All healthy shows stats") func testStatsDefault() {
        #expect(resolve(lastGlucoseDate: fresh) == .stats)
    }

    @Test("Missing notifications outranks everything") func testNotificationsTop() {
        #expect(resolve(
            notificationsDisabled: true,
            pumpTimeMismatch: true,
            lastGlucoseDate: nil,
            maxIOB: 0
        ) == .notificationsDisabled)
    }

    @Test("Pump time mismatch outranks CGM and MaxIOB") func testTimeMismatchSecond() {
        #expect(resolve(pumpTimeMismatch: true, lastGlucoseDate: nil, maxIOB: 0) == .pumpTimeMismatch)
    }

    @Test("Stale glucose outranks MaxIOB") func testCgmStaleThird() {
        #expect(resolve(lastGlucoseDate: stale, maxIOB: 0) == .cgmStale)
    }

    @Test("No glucose at all counts as stale") func testNoGlucoseIsStale() {
        #expect(resolve(lastGlucoseDate: nil) == .cgmStale)
    }

    @Test("Fresh glucose within threshold is not stale") func testFreshGlucose() {
        #expect(resolve(lastGlucoseDate: now.addingTimeInterval(-11 * 60)) == .stats)
    }

    @Test("MaxIOB zero shows its warning") func testMaxIOBZero() {
        #expect(resolve(lastGlucoseDate: fresh, maxIOB: 0) == .maxIOBZero)
    }

    @Test("Bolus in progress beats every warning") func bolusBeatsAll() {
        #expect(resolve(
            bolusInProgress: true,
            notificationsDisabled: true,
            lastGlucoseDate: stale,
            maxIOB: 0,
            hasOverride: true
        ) == .bolusProgress)
    }

    @Test("Adjustments beat stats but not warnings") func adjustmentPriority() {
        #expect(resolve(lastGlucoseDate: fresh, hasTempTarget: true) == .adjustments(.tempTarget))
        #expect(resolve(lastGlucoseDate: stale, hasTempTarget: true) == .cgmStale)
    }

    @Test("Adjustment sub-state precedence") func adjustmentSubState() {
        #expect(resolve(lastGlucoseDate: fresh, hasOverride: true, hasTempTarget: true) == .adjustments(.dual))
        #expect(resolve(lastGlucoseDate: fresh, hasOverride: true) == .adjustments(.override))
        #expect(resolve(lastGlucoseDate: fresh, hasTempProfile: true) == .adjustments(.profile))
        #expect(resolve(lastGlucoseDate: fresh) == .stats)
    }
}
