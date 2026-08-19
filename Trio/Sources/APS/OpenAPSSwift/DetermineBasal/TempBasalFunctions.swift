import Foundation

enum TempBasalFunctionError: LocalizedError, Equatable {
    case invalidBasalRateOnProfile

    var errorDescription: String? {
        switch self {
        case .invalidBasalRateOnProfile:
            return "The currentBasal, maxBasal, or maxDailyBasal wasn't set on Profile"
        }
    }
}

enum TempBasalFunctions {
    /// Rounds basal rates to the increment the pump delivers in, in U100 units.
    ///
    /// Diverges from JS `round-basal.js`, which bands at 1 and 10 U/h using constants copied from a
    /// Medtronic x23. Those boundaries are in pump units while the rate here is in U100 units, so
    /// they only line up at U100, and the constants discard resolution on every pump with a flat
    /// grid - a pod loses half its steps above 10 U/h, a Dana four fifths above 1. A banded pump is
    /// handed a rate finer than it can hold instead, which `roundToSupportedBasalRate` floors when
    /// the rate is converted back to pump volume for delivery.
    static func roundBasal(profile: Profile, basalRate: Decimal) -> Decimal {
        var scale: Decimal = 20
        if profile.basalIncrement > 0 {
            scale = 1 / profile.basalIncrement
        }

        return (basalRate * scale).jsRounded() / scale
    }

    /// defines the max safe basal rate given a profile
    static func getMaxSafeBasalRate(profile: Profile) throws -> Decimal {
        // use default values if either of these are NaN
        let maxDailySafetyMultiplier = profile.maxDailySafetyMultiplier.isNaN ? 3 : profile.maxDailySafetyMultiplier
        let currentBasalSafetyMultiplier = profile.currentBasalSafetyMultiplier.isNaN ? 4 : profile.currentBasalSafetyMultiplier

        guard let currentBasal = profile.currentBasal, let maxDailyBasal = profile.maxDailyBasal,
              let maxBasal = profile.maxBasal
        else {
            throw TempBasalFunctionError.invalidBasalRateOnProfile
        }

        return min(
            maxBasal,
            maxDailySafetyMultiplier * maxDailyBasal,
            currentBasalSafetyMultiplier * currentBasal
        )
    }

    static func setTempBasal(
        rate: Decimal,
        duration: Decimal,
        profile: Profile,
        determination: Determination,
        currentTemp: TempBasal,
        iobInputs: KetoProtect.IobInputs = .empty
    ) throws -> Determination {
        var determination = determination
        let maxSafeBasal = try getMaxSafeBasalRate(profile: profile)

        var rate = rate
        if rate < 0 {
            rate = 0
        } else if rate > maxSafeBasal {
            rate = maxSafeBasal
        }

        var suggestedRate = roundBasal(profile: profile, basalRate: rate)

        let keto = KetoProtect.apply(
            rate: suggestedRate,
            profile: profile,
            iobInputs: iobInputs
        )
        suggestedRate = keto.rate
        if !keto.reason.isEmpty {
            determination.reason = keto.reason + determination.reason
        }

        if Decimal(currentTemp.duration) > (duration - 10),
           currentTemp.duration <= 120,
           suggestedRate <= currentTemp.rate * 1.2,
           suggestedRate >= currentTemp.rate * 0.8,
           duration > 0
        {
            determination
                .reason += " \(currentTemp.duration)m left and \(currentTemp.rate) ~ req \(suggestedRate)U/hr: no temp required"
            return determination
        }

        if suggestedRate == profile.currentBasal {
            if profile.skipNeutralTemps {
                if currentTemp.duration > 0 {
                    determination
                        .reason = determination.reason +
                        ". Suggested rate is same as profile rate, a temp basal is active, canceling current temp"
                    determination.duration = 0
                    determination.rate = 0
                    return determination
                } else {
                    determination
                        .reason = determination.reason +
                        ". Suggested rate is same as profile rate, no temp basal is active, doing nothing"
                    return determination
                }
            } else {
                determination.reason = determination.reason + ". Setting neutral temp basal of \(profile.currentBasal ?? 0)U/hr"
                determination.duration = duration
                determination.rate = suggestedRate
                return determination
            }
        } else {
            determination.duration = duration
            determination.rate = suggestedRate
            return determination
        }
    }
}
