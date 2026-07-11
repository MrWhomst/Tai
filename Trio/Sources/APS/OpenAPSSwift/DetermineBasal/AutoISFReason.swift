import Foundation

/// Reason-string fragments contributed by autoISF 3.01.
///
/// Every tag autoISF adds or prepends to a `Determination.reason` lives here so the
/// user-visible wording stays manageable in one file. Functions are pure — they
/// return strings; callers re-assign onto the Determination.
enum AutoISFReason {
    // MARK: - Prepends

    /// "Ins.Req:, <amount>, " — matches JS `determine-basal.js:1801`. Emitted on the
    /// aggressive-dosing path (SMB and high-temp) after the required insulin is known.
    /// Returns the reason unchanged when `insulinRequired` is zero or negative —
    /// nothing useful to highlight in the popup header.
    static func prependingInsulinRequired(_ insulinRequired: Decimal, to reason: String) -> String {
        guard insulinRequired > 0 else { return reason }
        return "Ins.Req:, \(insulinRequired), " + reason
    }

    // MARK: - Tags

    /// "SMB Del.Ratio:, <ratio>, " — the effective SMB delivery ratio used for dosing
    /// (ramped or fixed, depending on BG-range configuration and loop mode).
    static func smbDeliveryRatioTag(_ ratio: Decimal) -> String {
        "SMB Del.Ratio:, \(ratio.jsRounded(scale: 2)), "
    }

    /// Sensitivity-ratio chip at the start of the reason. Labels are mutually exclusive —
    /// `Ratio TT:` when the ratio came from the temp-target half-basal-target curve,
    /// `autosens:` when it came from autosens.
    static func sensitivityRatioTag(ratio: Decimal, fromTempTarget: Bool) -> String {
        if fromTempTarget {
            return "Ratio TT:, \(ratio.jsRounded(scale: 2)), "
        }
        return "autosens:, \(ratio.jsRounded(scale: 2)), "
    }

    /// Bypass cause for the autoISF adjustment path — drives the disabled-state chip.
    enum AutoISFBypassCause {
        /// autoISF disabled in preferences.
        case preferenceDisabled
        /// autoISF_off_Sport active and exercise mode triggered.
        case exerciseDisabled
    }

    /// Reason fragment for the autoISF-bypass paths. Produces something like
    /// `"[smbFragment, ]Ratio TT:, 0.3, autoISF disabled (exercise), Standard"` when
    /// the TT modifier fires and autoISF_off_Sport is active.
    static func autosensOnlyReason(
        ratio: Decimal,
        fromTempTarget: Bool,
        bypassCause: AutoISFBypassCause?,
        smbFragment: String
    ) -> String {
        let smbStr = smbFragment.isEmpty ? "" : "\(smbFragment), "
        let ratioStr = sensitivityRatioTag(ratio: ratio, fromTempTarget: fromTempTarget)
        let bypassStr: String = {
            switch bypassCause {
            case .exerciseDisabled: return "autoISF disabled (exercise), "
            case .preferenceDisabled: return "autoISF disabled, "
            case .none: return ""
            }
        }()
        return "\(smbStr)\(ratioStr)\(bypassStr)Standard"
    }

    /// "Parabolic Fit:, …, " — displayed when BG-acceleration ISF is actually adjusting
    /// ISF, the fit is reliable, and the extremum and time delta are in sensible ranges.
    /// Returns an empty string when no tag should be shown.
    static func parabolaFitTag(
        enabled: Bool,
        acceISFratio: Decimal,
        status: AutoISFGlucoseStatus
    ) -> String {
        // Preconditions: autoISF acceleration is active, parabola has curvature, fit is
        // reliable, and |bg_acceleration| is meaningful (a near-linear parabola extrapolates
        // a distant, unreliable vertex — e.g. a "max hrs ago" over a BG curve that was
        // actually flat back then).
        guard enabled,
              acceISFratio != 1,
              status.a_2 != 0,
              status.r_squ >= Decimal(0.9),
              abs(status.bg_acceleration) >= Decimal(0.3)
        else { return "" }

        let tVertex = -(status.a_1 / (2 * status.a_2))
        let minsDelta = (abs(tVertex) * 5).jsRounded(scale: 0)
        // Round to integer mg/dL — mmol/L conversion (one decimal) is handled downstream by
        // TagCloudView/NightscoutManager via the parabola regex + convertToMmolL.
        let extremumBG = (status.a_0 - status.a_1 * status.a_1 / (4 * status.a_2)).jsRounded()

        // Sanity bounds on extremum BG and time, plus: reject a past-extrapolation whose
        // predicted slope contradicts a historically stable long-term average delta.
        let pastInconsistentWithHistory =
            tVertex < 0 && minsDelta > 60 && abs(status.glucoseStatus.longAvgDelta) < 1
        guard extremumBG >= -200,
              extremumBG <= 400,
              minsDelta <= 300,
              !pastInconsistentWithHistory
        else { return "" }

        if tVertex > 0 {
            return status.bg_acceleration < 0
                ? "Parabolic Fit:, predicts Max of \(extremumBG), in about \(minsDelta)min, "
                : "Parabolic Fit:, predicts Min of \(extremumBG), in about \(minsDelta)min, "
        } else {
            return status.bg_acceleration < 0
                ? "Parabolic Fit:, saw Max of \(extremumBG), about \(minsDelta)min ago, "
                : "Parabolic Fit:, saw Min of \(extremumBG), about \(minsDelta)min ago, "
        }
    }

    /// Assembles the full ISF reason: `[ratio] [smb] [parabola] <adjust>, Standard`.
    /// `fromTempTarget=true` swaps the leading `autosens:` chip for `Ratio TT:`.
    static func isfReason(
        autosensEnabled: Bool,
        sensitivityRatio: Decimal,
        fromTempTarget: Bool,
        smbFragment: String,
        parabolaFragment: String,
        adjustReason: String
    ) -> String {
        let ratioStr: String = (autosensEnabled || fromTempTarget)
            ? sensitivityRatioTag(ratio: sensitivityRatio, fromTempTarget: fromTempTarget)
            : ""
        let smbStr = smbFragment.isEmpty ? "" : "\(smbFragment), "
        return "\(ratioStr)\(smbStr)\(parabolaFragment)\(adjustReason), Standard"
    }

    // MARK: - SMB control fragments (AutoISFsmb outputs)

    /// Tail appended to "Microbolusing Xu" when the autoISF iobTH 130 % cap reduced
    /// the SMB. Mirrors JS `, capped by autoISF iobTH`.
    static let smbCappedByIobTH = ", capped by autoISF iobTH"

    static let smbBlockedOverride = "SMB disabled:, Override"
    static let smbBlockedB30Running = "SMB disabled:, B30 running"
    static func smbBlockedIobTHExceeded(iobThEffective: Decimal) -> String {
        "autoISF-SMB disabled:, eff.iobTH:, \(iobThEffective) exceeded"
    }

    static let smbBlockedOddTarget = "autoISF-SMB disabled:, odd Target"
    static let smbBlockedMaxIobZero = "autoISF-SMB disabled:, maxIOB=0"
    /// Even target would enforce SMBs, but the user's SMB settings have them off —
    /// user settings win; autoISF may only gate SMBs, never grant them.
    static let smbBlockedSettingsOff = "autoISF-SMB disabled:, SMBs off in settings"

    /// "autoISF-SMB enabled:, even TT, eff.iobTH:, <value>" — full-loop mode (even temp
    /// target below 100 mg/dL).
    static func smbEnabledFullLoop(iobThEffective: Decimal) -> String {
        "autoISF-SMB enabled:, even TT, eff.iobTH:, \(iobThEffective)"
    }

    /// "autoISF-SMB enabled:, even Target, eff.iobTH:, <value>" — enforced mode (even
    /// target at or above 100 mg/dL).
    static func smbEnabledEnforced(iobThEffective: Decimal) -> String {
        "autoISF-SMB enabled:, even Target, eff.iobTH:, \(iobThEffective)"
    }

    /// SMB-section chip text used when the autoISF iobTH 130 % cap reduced the SMB.
    /// Shows the effective iobTH (`iob_threshold_percent * max_iob`) that triggered
    /// the cap — the resulting capped microbolus value is already shown in the
    /// "Microbolusing <X>U" conclusion line, so we don't repeat it here.
    static func smbCappedByIobTHTag(iobThEffective: Decimal) -> String {
        "eff.iobTH:, capped at \(iobThEffective)"
    }

    /// Tags an autoISF SMB reason as having been capped by the iobTH 130 % overrun cap.
    /// - When the even/odd toggle is on, the reason already carries an `, even TT,` /
    ///   `, even Target,` chip — we replace that chip in-place with `capped by iobTH:, <X>`.
    /// - When the toggle is off, no such chip exists; we insert a fresh
    ///   `, capped by iobTH:, <X>` chip immediately before the first `; ` conclusion
    ///   separator, so the chip cloud (which keys off `; `) renders it next to the
    ///   other chips.
    static func applyIobTHCapTag(to reason: String, iobThEffective: Decimal) -> String {
        let tag = smbCappedByIobTHTag(iobThEffective: iobThEffective)
        if reason.contains(", even TT,") {
            return reason.replacingOccurrences(of: ", even TT,", with: ", \(tag),")
        }
        if reason.contains(", even Target,") {
            return reason.replacingOccurrences(of: ", even Target,", with: ", \(tag),")
        }
        guard let separatorRange = reason.range(of: "; ") else {
            return reason + ", \(tag)"
        }
        return reason.replacingCharacters(in: separatorRange, with: ", \(tag); ")
    }

    // MARK: - ISF adjustment fragments (AutoISFAdjust outputs)

    /// Reason when no autoISF factor modifies ISF.
    static let adjustNotModified = "autoISF: not modified"

    /// Reason for the decelerating-only path: acce-ISF (if != 1) and bg-ISF only.
    static func adjustDeceleratingReason(
        acceISFratio: Decimal,
        bgISFratio: Decimal,
        finalISF: Decimal,
        profileSens: Decimal,
        adjustedSens: Decimal
    ) -> String {
        (acceISFratio != 1 ? "acce-ISF Ratio:, \(acceISFratio.jsRounded(scale: 2)), " : "") +
            "autoISF, bg-ISF Ratio: \(bgISFratio.jsRounded(scale: 2))" +
            ", final Ratio:, \(finalISF.jsRounded(scale: 2))" +
            ", final ISF:, \(profileSens.jsRounded())→\(adjustedSens.jsRounded())"
    }

    /// Full autoISF adjustment reason: includes whichever factors actually changed.
    static func adjustFullReason(
        acceISFratio: Decimal,
        bgISFratio: Decimal,
        ppISFratio: Decimal,
        duraISFratio: Decimal,
        dura05: Decimal,
        avg05: Decimal,
        finalISF: Decimal,
        profileSens: Decimal,
        adjustedSens: Decimal
    ) -> String {
        var parts: [String] = []
        if acceISFratio != 1 { parts.append("acce-ISF Ratio:, \(acceISFratio.jsRounded(scale: 2))") }
        parts.append("autoISF")
        if bgISFratio != 1 { parts.append("bg-ISF Ratio: \(bgISFratio.jsRounded(scale: 2))") }
        if ppISFratio != 1 { parts.append("pp-ISF Ratio: \(ppISFratio.jsRounded(scale: 2))") }
        if duraISFratio != 1 {
            parts.append(
                "Duration: \(dura05.jsRounded()), Avg: \(avg05.jsRounded()), dura-ISF Ratio: \(duraISFratio.jsRounded(scale: 2))"
            )
        }
        parts.append(
            "final Ratio:, \(finalISF.jsRounded(scale: 2)), final ISF:, \(profileSens.jsRounded())→\(adjustedSens.jsRounded())"
        )
        return parts.joined(separator: ", ")
    }
}
