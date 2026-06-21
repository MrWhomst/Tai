import Foundation
import Testing
@testable import Trio

/// Unit tests for `AutoISF.run` — the single-iteration orchestrator that
/// coordinates AutoISFsmb (always when autoISF is on) and AutoISFAdjust
/// (only when dynISF is inactive and glucose status is available).
@Suite("AutoISF Orchestrator Tests") struct AutoISFTests {
    private func makeProfile(
        autoisf: Bool = true,
        enableSMBEvenOnOddOffAlways: Bool = true,
        maxIob: Decimal = 10,
        smbDeliveryRatio: Decimal = Decimal(string: "0.5")!,
        smbDeliveryRatioBGrange: Decimal = 0,
        autoISFmin: Decimal = Decimal(string: "0.7")!,
        autoISFmax: Decimal = Decimal(string: "1.2")!
    ) -> Profile {
        var profile = Profile()
        profile.autoisf = autoisf
        profile.enableSMBEvenOnOddOffAlways = enableSMBEvenOnOddOffAlways
        profile.maxIob = maxIob
        profile.smbDeliveryRatio = smbDeliveryRatio
        profile.smbDeliveryRatioBGrange = smbDeliveryRatioBGrange
        profile.smbDeliveryRatioMin = Decimal(string: "0.4")!
        profile.smbDeliveryRatioMax = Decimal(string: "0.8")!
        profile.autoISFmin = autoISFmin
        profile.autoISFmax = autoISFmax
        return profile
    }

    private func makeGlucoseStatus(glucose: Decimal = 120) -> AutoISFGlucoseStatus {
        let base = GlucoseStatus(
            delta: 0,
            glucose: glucose,
            noise: 0,
            shortAvgDelta: 0,
            longAvgDelta: 0,
            date: Date(),
            lastCalIndex: nil,
            device: nil
        )
        return AutoISFGlucoseStatus(
            glucoseStatus: base,
            cgmFlatMinutes: 0,
            dura_ISF_minutes: 0,
            dura_ISF_average: 0,
            dura_p: 0,
            delta_pl: 0,
            delta_pn: 0,
            bg_acceleration: 0,
            r_squ: 0,
            a_0: 0,
            a_1: 0,
            a_2: 0,
            debugInfo: ""
        )
    }

    private func runEngine(
        profile: Profile,
        dynamicIsfActive: Bool = false,
        autoISFStatus: AutoISFGlucoseStatus? = nil,
        targetBG: Decimal = 100,
        currentGlucose: Decimal = 120,
        microBolusAllowed: Bool = true,
        iob: Decimal = 0,
        b30IsActive: Bool = false,
        overrideSmbIsOff: Bool = false
    ) -> AutoISFEngineResult {
        AutoISF.run(
            profile: profile,
            dynamicIsfActive: dynamicIsfActive,
            adjustedSensitivity: 50,
            profileSens: 50,
            targetBG: targetBG,
            units: .mgdL,
            currentGlucose: currentGlucose,
            sensitivityRatio: 1,
            originalSensitivity: 50,
            microBolusAllowed: microBolusAllowed,
            iob: iob,
            b30IsActive: b30IsActive,
            autoISFStatus: autoISFStatus,
            overrideSmbIsOff: overrideSmbIsOff
        )
    }

    @Test("Skips ISF adjustment but still runs SMB control when dynISF is active") func dynISFActiveSkipsAdjust() throws {
        let profile = makeProfile()
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, dynamicIsfActive: true, autoISFStatus: status)

        #expect(result.adjustedSensitivity == nil)
        #expect(result.adjustResult == nil)
        #expect(result.smbResult != nil)
        #expect(result.smbEnabled == true) // even target 100, microbolus allowed → enforced
    }

    @Test("Skips ISF adjustment when glucose status is missing") func noGlucoseStatusSkipsAdjust() throws {
        let profile = makeProfile()

        let result = runEngine(profile: profile, autoISFStatus: nil)

        #expect(result.adjustedSensitivity == nil)
        #expect(result.adjustResult == nil)
        #expect(result.smbResult != nil)
    }

    @Test("Runs ISF adjustment when dynISF is off and status is available") func runsAdjustWhenEligible() throws {
        let profile = makeProfile()
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, dynamicIsfActive: false, autoISFStatus: status)

        #expect(result.adjustResult != nil)
        // No weights are set → calculate returns the not-modified path with adjustedSens unchanged
        #expect(result.adjustedSensitivity == 50)
    }

    @Test("Returns nil smbEnabled when SMB defers to oref") func smbEnabledNilWhenOref() throws {
        // Even/odd toggle off → loopMode .oref → smbEnabled nil (caller falls back to oref logic)
        let profile = makeProfile(enableSMBEvenOnOddOffAlways: false)
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, autoISFStatus: status)

        #expect(result.smbResult?.loopMode == .oref)
        #expect(result.smbEnabled == nil)
    }

    @Test("Returns false smbEnabled when SMB is blocked") func smbEnabledFalseWhenBlocked() throws {
        let profile = makeProfile()
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, autoISFStatus: status, targetBG: 101) // odd target

        #expect(result.smbResult?.loopMode == .blocked)
        #expect(result.smbEnabled == false)
    }

    @Test("Returns true smbEnabled when SMB is enforced") func smbEnabledTrueWhenEnforced() throws {
        let profile = makeProfile()
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, autoISFStatus: status, targetBG: 100)

        #expect(result.smbResult?.loopMode == .enforced)
        #expect(result.smbEnabled == true)
    }

    @Test("smbResult is nil when autoISF is disabled") func smbResultNilWhenDisabled() throws {
        let profile = makeProfile(autoisf: false)

        let result = runEngine(profile: profile, autoISFStatus: nil)

        #expect(result.smbResult == nil)
        #expect(result.smbEnabled == nil)
        #expect(result.adjustResult == nil)
    }

    @Test("smbRatio is clamped to 1") func smbRatioClampedToOne() throws {
        // Set max ratio above 1 — engine clamps to 1
        var profile = makeProfile()
        profile.smbDeliveryRatio = Decimal(string: "1.5")!
        let status = makeGlucoseStatus()

        let result = runEngine(profile: profile, autoISFStatus: status)

        #expect(result.smbRatio == 1)
    }
}
