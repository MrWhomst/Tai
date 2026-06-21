import Foundation

/// The SMB loop-mode an autoISF evaluation resolves to. Consumed by
/// `AutoISFsmb.variableSMBRatio` and by the SMB dosing path in
/// `DosingEngine.determineSMBDelivery` to decide whether the `max(fixed, ramp)`
/// full-loop floor applies.
enum AutoISFLoopMode {
    case oref // fall through to standard SMB enabling logic
    case enforced // SMB on — even target at normal BG
    case fullLoop // SMB on — even temp-target below 100
    case blocked // SMB off — odd target
    case iobTHExceeded // SMB off — IOB exceeds threshold
    case b30Running // SMB off — B30 basal active
}

/// Consolidated result from  autoISF  for one loop iteration.
struct AutoISFEngineResult {
    /// Adjusted ISF — replaces the caller's `adjustedSensitivity` when non-nil.
    let adjustedSensitivity: Decimal?
    /// SMB enabled override — nil means defer to standard oref logic.
    let smbEnabled: Bool?
    /// Full ISF reason string, always populated.
    let isfReason: String
    /// Effective SMB delivery ratio (ramped or fixed), already clamped to `[0, 1]`.
    /// DosingEngine uses this for the microbolus amount; also stored in Determination.
    let smbRatio: Decimal
    /// ISF sub-module result (for Determination ratio fields).
    let adjustResult: AutoISFAdjustResult?
    /// SMB sub-module result (for iobTH field).
    let smbResult: AutoISFsmbResult?
    /// AutoISF glucose status (for Determination parabola / dura / acce fields).
    let glucoseStatus: AutoISFGlucoseStatus?
    /// True when the autoISF ISF-adjustment path was bypassed — autoISF disabled
    /// in the profile, or exercise mode plus autoISF_off_Sport. Drives the
    /// sentinel-1 telemetry on the parabola/dura/bg_acce/acce_ISF/bg_ISF/pp_ISF/
    /// dura_ISF determination fields so the bypass output is well-defined.
    let isfAdjustBypassed: Bool
}

/// Coordinates all autoISF sub-modules for a single loop iteration.
///
/// Callers pass their current `adjustedSensitivity` and receive back a result
/// bundle: one field to update sens, one to override SMB, one ready-to-use
/// reason string, and sub-results for the Determination struct.
///
/// SMB control runs whenever autoISF is enabled, regardless of dynISF.
/// ISF adjustment only runs when dynISF is inactive.
enum AutoISF {
    /// Apply override values from `trioCustomOrefVariables` onto the autoISF/SMB
    /// fields of `profile`. No-op when `useOverride` is false; per-field guard
    /// preserves the profile value whenever the override is nil.
    static func applyProfileOverrides(
        _ profile: inout Profile,
        from trioCustomOrefVariables: TrioCustomOrefVariables
    ) {
        guard trioCustomOrefVariables.useOverride else { return }
        if let override = trioCustomOrefVariables.overrideAutoISFmin {
            profile.autoISFmin = override
        }
        if let override = trioCustomOrefVariables.overrideAutoISFmax {
            profile.autoISFmax = override
        }
        if let override = trioCustomOrefVariables.overrideAutoISFhourlyChange {
            profile.autoISFhourlyChange = override
        }
        if let override = trioCustomOrefVariables.overrideHigherISFrangeWeight {
            profile.higherISFrangeWeight = override
        }
        if let override = trioCustomOrefVariables.overrideLowerISFrangeWeight {
            profile.lowerISFrangeWeight = override
        }
        if let override = trioCustomOrefVariables.overridePostMealISFweight {
            profile.postMealISFweight = override
        }
        if let override = trioCustomOrefVariables.overrideBgAccelISFweight {
            profile.bgAccelISFweight = override
        }
        if let override = trioCustomOrefVariables.overrideBgBrakeISFweight {
            profile.bgBrakeISFweight = override
        }
        if let override = trioCustomOrefVariables.overrideIobThresholdPercent {
            profile.iobThresholdPercent = override
        }
        if let override = trioCustomOrefVariables.overrideSmbDeliveryRatio {
            profile.smbDeliveryRatio = override
        }
        if let override = trioCustomOrefVariables.overrideSmbDeliveryRatioBGrange {
            profile.smbDeliveryRatioBGrange = override
        }
        if let override = trioCustomOrefVariables.overrideSmbDeliveryRatioMin {
            profile.smbDeliveryRatioMin = override
        }
        if let override = trioCustomOrefVariables.overrideSmbDeliveryRatioMax {
            profile.smbDeliveryRatioMax = override
        }
        if let override = trioCustomOrefVariables.overrideEnableBGacceleration {
            profile.enableBGacceleration = override
        }
    }

    /// TT half-basal-target mode flags for the given profile and target.
    /// `targetBG` is the post-TT-overwrite target (i.e. the user's TT value when one is active).
    /// Predicate matches JS oref's `target_bg > normalTarget` / `< normalTarget` literal-100 gate.
    static func tempTargetMode(
        profile: Profile,
        targetBG: Decimal
    ) -> (exerciseModeActive: Bool, resistanceModeActive: Bool) {
        let normalTarget: Decimal = 100
        let temptargetSet = profile.temptargetSet ?? false
        let exerciseModeActive = profile.highTemptargetRaisesSensitivity && temptargetSet && targetBG > normalTarget
        let resistanceModeActive = profile.lowTemptargetLowersSensitivity && temptargetSet && targetBG < normalTarget
        return (exerciseModeActive, resistanceModeActive)
    }

    static func run(
        profile: Profile,
        dynamicIsfActive: Bool,
        adjustedSensitivity: Decimal,
        profileSens: Decimal,
        targetBG: Decimal,
        units: GlucoseUnits,
        currentGlucose: Decimal,
        sensitivityRatio: Decimal,
        originalSensitivity _: Decimal,
        microBolusAllowed: Bool,
        iob: Decimal,
        b30IsActive: Bool,
        autoISFStatus: AutoISFGlucoseStatus?,
        overrideSmbIsOff: Bool
    ) -> AutoISFEngineResult {
        let (exerciseModeActive, resistanceModeActive) = tempTargetMode(profile: profile, targetBG: targetBG)
        // Drives the iobTH reduction inside AutoISFsmb when iob_threshold_percent != 1.
        let exerciseRatio: Decimal = (exerciseModeActive || resistanceModeActive) ? sensitivityRatio : 1

        // Bypass-path reason builder: emits the chip set for the
        // (Ratio TT or autosens, autoISF disabled[ (exercise)], Standard) cluster.
        func bypassReason(cause: AutoISFReason.AutoISFBypassCause?) -> String {
            AutoISFReason.autosensOnlyReason(
                ratio: sensitivityRatio,
                fromTempTarget: exerciseModeActive || resistanceModeActive,
                bypassCause: cause,
                smbFragment: ""
            )
        }

        // SMB control: runs whenever autoISF is enabled, independent of dynISF
        let smbResult = OrefSubTimer.time("autoISF.AutoISFsmb.evaluate") {
            AutoISFsmb.evaluate(
                profile: profile,
                targetBG: targetBG,
                units: units,
                microBolusAllowed: microBolusAllowed,
                iob: iob,
                b30IsActive: b30IsActive,
                exerciseRatio: exerciseRatio,
                overrideSmbIsOff: overrideSmbIsOff
            )
        }
        let smbEnabled: Bool? = smbResult.flatMap { $0.loopMode != .oref ? $0.smbEnabled : nil }

        // Effective SMB delivery ratio (fixed or BG-range-ramped), pre-computed once so
        // DosingEngine and Determination can read the same value.
        let smbRatio = OrefSubTimer.time("autoISF.AutoISFsmb.variableSMBRatio") {
            min(
                AutoISFsmb.variableSMBRatio(
                    profile: profile,
                    currentGlucose: currentGlucose,
                    targetGlucose: targetBG,
                    loopMode: smbResult?.loopMode ?? .oref
                ),
                1
            )
        }

        // True when the autoISF ISF-adjustment path is bypassed: autoISF disabled in
        // preferences, or exercise mode plus autoISF_off_Sport. Used to drive the
        // sentinel-1 telemetry on the determination output.
        let isfAdjustBypassed = !profile.autoisf || (profile.autoISFoffSport && exerciseModeActive)

        // ISF adjustment runs only when dynISF is inactive and glucose status is
        // available; otherwise emit the bypass-path chip cluster.
        guard !dynamicIsfActive, let status = autoISFStatus else {
            return AutoISFEngineResult(
                adjustedSensitivity: nil,
                smbEnabled: smbEnabled,
                isfReason: bypassReason(cause: !profile.autoisf ? .preferenceDisabled : nil),
                smbRatio: smbRatio,
                adjustResult: nil,
                smbResult: smbResult,
                glucoseStatus: autoISFStatus,
                isfAdjustBypassed: isfAdjustBypassed
            )
        }

        let adjustResult = OrefSubTimer.time("autoISF.AutoISFAdjust.calculate") {
            AutoISFAdjust.calculate(
                sens: adjustedSensitivity,
                profileSens: profileSens,
                targetBG: targetBG,
                profile: profile,
                glucoseStatus: status,
                sensitivityRatio: sensitivityRatio,
                exerciseModeActive: exerciseModeActive,
                resistanceModeActive: resistanceModeActive
            )
        }

        let isfReason: String
        if let adjustResult = adjustResult {
            isfReason = AutoISFReason.isfReason(
                autosensEnabled: profile.enableAutosens,
                sensitivityRatio: sensitivityRatio,
                fromTempTarget: exerciseModeActive || resistanceModeActive,
                smbFragment: smbResult?.reason ?? "",
                parabolaFragment: AutoISFReason.parabolaFitTag(
                    enabled: profile.enableBGacceleration,
                    acceISFratio: adjustResult.acceISFratio,
                    status: status
                ),
                adjustReason: adjustResult.reason
            )
        } else {
            // AutoISFAdjust returned nil — pick the matching disabled-cause for the chip.
            let cause: AutoISFReason.AutoISFBypassCause = (profile.autoISFoffSport && exerciseModeActive)
                ? .exerciseDisabled
                : .preferenceDisabled
            isfReason = bypassReason(cause: cause)
        }

        return AutoISFEngineResult(
            adjustedSensitivity: adjustResult?.adjustedSens,
            smbEnabled: smbEnabled,
            isfReason: isfReason,
            smbRatio: smbRatio,
            adjustResult: adjustResult,
            smbResult: smbResult,
            glucoseStatus: status,
            isfAdjustBypassed: isfAdjustBypassed || adjustResult == nil
        )
    }

    /// Outcome of the autoISF B30 dispatch. `notActive` → caller runs the standard
    /// oref dosing pipeline. `delivered` or `blocked` → caller returns the determination
    /// as-is (B30 took over either by boosting basal or by committing a safeguard fallback).
    enum B30Dispatch {
        case notActive
        case delivered(Determination)
        case blocked(Determination)
    }

    /// Mirrors JS `aimiRateActivated` branch — activation check, safeguard overlay,
    /// KetoProtect gate, and post-block SMB re-evaluation all live here so the top-level
    /// generator only has to ask autoISF for the outcome.
    ///
    /// - When safeguards suppress B30, AutoISFsmb is re-evaluated with `b30IsActive=false`
    ///   so the returned determination's `smbRatio` / `iobTH` / displayed SMB state reflect
    ///   the post-block reality (B30 isn't actually running).
    static func dispatchB30(
        b30Result: B30Result,
        determination: Determination,
        safetyInputs: B30SafetyInputs,
        profile: Profile,
        targetBG: Decimal,
        units: GlucoseUnits,
        currentGlucose: Decimal,
        microBolusAllowed: Bool,
        iob: Decimal,
        sensitivityRatio: Decimal,
        overrideSmbIsOff: Bool,
        iobInputs: KetoProtect.IobInputs
    ) throws -> B30Dispatch {
        guard b30Result.isActive else { return .notActive }

        let (suppressed, afterSafeguards) = try AimiB30.applySafetyChecks(
            inputs: safetyInputs,
            determination: determination
        )

        if suppressed {
            var blocked = afterSafeguards
            let (exerciseModeActive, resistanceModeActive) = tempTargetMode(profile: profile, targetBG: targetBG)
            // Drives the iobTH reduction inside AutoISFsmb when iob_threshold_percent != 1.
            let exerciseRatio: Decimal = (exerciseModeActive || resistanceModeActive) ? sensitivityRatio : 1
            let updatedSmb = AutoISFsmb.evaluate(
                profile: profile,
                targetBG: targetBG,
                units: units,
                microBolusAllowed: microBolusAllowed,
                iob: iob,
                b30IsActive: false,
                exerciseRatio: exerciseRatio,
                overrideSmbIsOff: overrideSmbIsOff
            )
            blocked.smbRatio = min(
                AutoISFsmb.variableSMBRatio(
                    profile: profile,
                    currentGlucose: currentGlucose,
                    targetGlucose: targetBG,
                    loopMode: updatedSmb?.loopMode ?? .oref
                ),
                1
            )
            blocked.iobTH = updatedSmb?.iobTHEffective
            return .blocked(blocked)
        }

        // Safeguards passed → deliver B30 boost. KetoProtect mirrors JS basal-set-temp.js
        // where keto check precedes the aimiRateActivated branch.
        var det = afterSafeguards
        let keto = KetoProtect.apply(
            rate: b30Result.boostRate,
            profile: profile,
            iobInputs: iobInputs
        )
        det.reason = keto.reason + b30Result.reason + det.reason
        det.reason = "AIMI B30, TBR \(keto.rate)U/hr" + det.reason
        det.reason += "calculated AIMI B30 Temp \(keto.rate)U/hr\(b30Result.reason)"
        det.rate = keto.rate
        det.duration = min(30, b30Result.remainingMinutes)
        return .delivered(det)
    }
}
