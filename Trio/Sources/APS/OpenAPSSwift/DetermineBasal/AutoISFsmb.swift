import Foundation

/// Output of the autoISF SMB-activation decision.
struct AutoISFsmbResult {
    let loopMode: AutoISFLoopMode
    /// Effective IOB threshold value (for logging). 100 % of `iob_threshold_percent * max_iob`.
    let iobTHEffective: Decimal
    /// 130 %-tolerance virtual IOB ceiling used by `applyIobTHcap`. Mirrors JS `iobTHvirtual`.
    let iobTHVirtual: Decimal
    /// Reason fragment to prepend to the determination reason string.
    let reason: String

    var smbEnabled: Bool { loopMode == .enforced || loopMode == .fullLoop }
}

/// autoISF-specific SMB logic: ports `loop_smb()` (enable/disable decision) and
/// `determine_varSMBratio()` (variable delivery-ratio ramp) from
/// determine-basal.js (autoISF 3.01).
///
/// `evaluate` returns `nil` when autoISF is disabled (caller falls back to
/// standard SMB logic) and `.oref` when autoISF defers to oref's own SMB
/// enabling logic (same fallback).
enum AutoISFsmb {
    /// 130 % overrun tolerance allowed by the iobTH cap — a single SMB may push
    /// IOB at most `iobTHTolerance × iob_threshold_percent × max_iob`. Mirrors
    /// `iobTHtolerance = 130` (percent) in determine-basal.js (autoISF 3.01).
    static let iobTHTolerance: Decimal = 1.3

    /// Multiplies the upstream-computed SMB max bolus by `smb_max_range_extension`
    /// when autoISF is on. With autoISF off, returns the input unchanged so the
    /// pre-autoISF cap (`current_basal × override_factor × maxSMBBasalMinutes / 60`)
    /// is preserved exactly.
    static func applySmbMaxRange(profile: Profile, maxBolus: Decimal) -> Decimal {
        guard profile.autoisf else { return maxBolus }
        return (maxBolus * profile.smbMaxRangeExtension).jsRounded(scale: 1)
    }

    static func evaluate(
        profile: Profile,
        targetBG: Decimal,
        units: GlucoseUnits,
        microBolusAllowed: Bool,
        iob: Decimal,
        b30IsActive: Bool,
        exerciseRatio: Decimal,
        overrideSmbIsOff: Bool
    ) -> AutoISFsmbResult? {
        guard profile.autoisf else { return nil }

        // iob_threshold_percent == 1 (100 %) disables the iobTH method
        let useIobTH = profile.iobThresholdPercent != 1
        let (iobThEffective, iobThVirtual) = iobTHValues(profile: profile, exerciseRatio: exerciseRatio)

        // Override disabling SMB wins over all autoISF SMB logic
        if overrideSmbIsOff {
            return AutoISFsmbResult(
                loopMode: .blocked,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbBlockedOverride
            )
        }

        // B30 basal active → SMB off (placeholder until B30 module is ported)
        if b30IsActive {
            return AutoISFsmbResult(
                loopMode: .b30Running,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbBlockedB30Running
            )
        }

        guard microBolusAllowed else {
            return AutoISFsmbResult(
                loopMode: .oref,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: ""
            )
        }

        // IOB threshold: disable SMB if IOB exceeds effective threshold
        if useIobTH, iobThEffective < iob {
            return AutoISFsmbResult(
                loopMode: .iobTHExceeded,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbBlockedIobTHExceeded(iobThEffective: iobThEffective)
            )
        }

        // Even/odd target override — only active when setting is enabled
        guard profile.enableSMBEvenOnOddOffAlways else {
            return AutoISFsmbResult(
                loopMode: .oref,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: ""
            )
        }

        let evenTarget: Bool
        // Targets are always stored as mg/dL integers. For mmol/L users, convert to
        // mmol/L (1-decimal rounded) then check tenths-digit parity — mirrors JS
        // convert_bg + *10 %2.
        if units == .mmolL {
            evenTarget = Int(NSDecimalNumber(decimal: (targetBG.asMmolL * 10).jsRounded()).doubleValue) % 2 == 0
        } else {
            evenTarget = Int(NSDecimalNumber(decimal: targetBG).doubleValue) % 2 == 0
        }

        guard evenTarget else {
            return AutoISFsmbResult(
                loopMode: .blocked,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbBlockedOddTarget
            )
        }

        guard profile.maxIob > 0 else {
            return AutoISFsmbResult(
                loopMode: .blocked,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbBlockedMaxIobZero
            )
        }

        // Below-100 min_bg signals a temp target → full-loop power
        if targetBG < 100 {
            return AutoISFsmbResult(
                loopMode: .fullLoop,
                iobTHEffective: iobThEffective,
                iobTHVirtual: iobThVirtual,
                reason: AutoISFReason.smbEnabledFullLoop(iobThEffective: iobThEffective)
            )
        }
        return AutoISFsmbResult(
            loopMode: .enforced,
            iobTHEffective: iobThEffective,
            iobTHVirtual: iobThVirtual,
            reason: AutoISFReason.smbEnabledEnforced(iobThEffective: iobThEffective)
        )
    }

    /// Computes the autoISF IOB-threshold values from the profile.
    ///
    /// Mirrors determine-basal.js (autoISF 3.01):
    /// - `iobThEffective` = `iob_threshold_percent * max_iob * iobTH_reduction_ratio`,
    ///   clamped to `max_iob` (JS `Math.min(profile.max_iob, iobThEffective)`).
    ///   Used by the gate (disable SMB when current IOB exceeds it).
    /// - `iobThVirtual`   = `iobTHTolerance × iob_threshold_percent × max_iob ×
    ///   iobTH_reduction_ratio`. The overrun ceiling used by `applyIobTHcap`.
    ///
    /// `iobTH_reduction_ratio` mirrors JS: equals `exercise_ratio` (sensitivityRatio
    /// from the temp-target half-basal curve when exercise/resistance mode is active,
    /// else 1) when `iob_threshold_percent != 1`, else 1.
    static func iobTHValues(profile: Profile, exerciseRatio: Decimal) -> (effective: Decimal, virtual: Decimal) {
        let reductionRatio: Decimal = profile.iobThresholdPercent != 1 ? exerciseRatio : 1
        let effective = min(
            profile.maxIob,
            profile.iobThresholdPercent * profile.maxIob * reductionRatio
        )
        let virtual = profile.iobThresholdPercent * iobTHTolerance * profile.maxIob * reductionRatio
        return (effective, virtual)
    }

    /// autoISF iobTH SMB cap. Mirrors determine-basal.js lines 1855-1864.
    ///
    /// If autoISF is enabled, the iobTH method is on (`iob_threshold_percent != 1`),
    /// and delivering this microBolus would push current IOB past
    /// `smbResult.iobTHVirtual`, the bolus is clamped so post-delivery IOB stays at
    /// the virtual ceiling. Returns the (possibly reduced) bolus, a reason tail to
    /// append to the "Microbolusing Xu" conclusion, and a chip-cloud reason rewritten
    /// to surface `eff.iobTH:, capped at <X>` next to the other autoISF chips.
    ///
    /// The cap fires regardless of `enableSMB_EvenOn_OddOff_always` — same principle
    /// as the gate, which was decoupled from the toggle in May 2025. If the user set
    /// iobTH < 100 %, they want it enforced. Returns the inputs unchanged when
    /// autoISF is disabled or `smbResult` is `nil`.
    static func applyIobTHcap(
        profile: Profile,
        currentIob: Decimal,
        microBolus: Decimal,
        smbResult: AutoISFsmbResult?,
        reason: String
    ) -> (microBolus: Decimal, reasonTail: String, reason: String) {
        guard profile.autoisf,
              profile.iobThresholdPercent != 1,
              let smbResult,
              microBolus > smbResult.iobTHVirtual - currentIob
        else {
            return (microBolus, "", reason)
        }
        return (
            smbResult.iobTHVirtual - currentIob,
            AutoISFReason.smbCappedByIobTH,
            AutoISFReason.applyIobTHCapTag(to: reason, iobThEffective: smbResult.iobTHEffective)
        )
    }

    /// Ports `determine_varSMBratio()` from determine-basal.js (autoISF 3.01).
    ///
    /// Produces the SMB delivery ratio to use for the microbolus calculation. When
    /// `smbDeliveryRatioBGrange > 0` the ratio ramps linearly from `smbDeliveryRatioMin`
    /// at BG target to `smbDeliveryRatioMax` at `target + bgRange`. With `bgRange == 0`
    /// the fixed `smbDeliveryRatio` is returned. In fullLoop mode the result is
    /// `max(fixed, ramp)` so the fixed ratio acts as a floor.
    static func variableSMBRatio(
        profile: Profile,
        currentGlucose: Decimal,
        targetGlucose: Decimal,
        loopMode: AutoISFLoopMode
    ) -> Decimal {
        // JS: if (bg_range < 10) bg_range /= 0.0555  → treat small values as mmol/L
        var bgRange = profile.smbDeliveryRatioBGrange
        if bgRange < 10 {
            bgRange /= Decimal(0.0555)
        }
        let fixSMB = profile.smbDeliveryRatio
        let lowerSMB = min(profile.smbDeliveryRatioMin, profile.smbDeliveryRatioMax)
        let higherSMB = max(profile.smbDeliveryRatioMin, profile.smbDeliveryRatioMax)
        let higherBG = targetGlucose + bgRange
        var newSMB = fixSMB

        if bgRange > 0 {
            newSMB = lowerSMB + (higherSMB - lowerSMB) * (currentGlucose - targetGlucose) / bgRange
            newSMB = max(lowerSMB, min(higherSMB, newSMB))
        }
        if loopMode == .fullLoop {
            return max(fixSMB, newSMB)
        }
        if bgRange == 0 {
            return fixSMB
        }
        if currentGlucose <= targetGlucose {
            return lowerSMB
        }
        if currentGlucose >= higherBG {
            return higherSMB
        }
        return newSMB
    }
}
