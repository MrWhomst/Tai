import Foundation

/// Resolves the bolus and basal increments stored in preferences from what the pump can deliver
/// and the insulin concentration in use.
///
/// Neither is a user setting: `BaseDeviceDataManager` overwrites both whenever a pump manager is
/// attached or cleared. They reach dosing through `Profile`, in U100 units - the algorithm works
/// in those, and `adjustPumpedRateToConcentration` converts back to pump volume before delivery,
/// where `roundToSupportedBasalRate` applies the pump's own grid.
enum PumpIncrementResolver {
    static let fallback: Decimal = 0.1
    static let basalFallback: Decimal = 0.05

    /// - Parameters:
    ///   - supportedBolusVolumes: `PumpManager.supportedBolusVolumes`, smallest first.
    ///   - currentIncrement: kept when the pump reports no volumes and concentration is U100.
    static func resolve(
        supportedBolusVolumes: [Double],
        currentIncrement: Decimal,
        concentration: Decimal
    ) -> Decimal {
        let supportedPumpIncrement = Decimal(supportedBolusVolumes.first ?? 0.1)
        var bolusIncrement = Decimal(supportedBolusVolumes.first ?? Double(currentIncrement))

        if concentration != 1 {
            bolusIncrement = supportedPumpIncrement * concentration
        }

        return bolusIncrement > 0 ? bolusIncrement : fallback
    }

    /// No pump attached, so there is no reported increment to scale.
    static func resolveWithoutPump(concentration: Decimal) -> Decimal {
        concentration != 1 ? fallback * concentration : fallback
    }

    /// Smallest rate the pump can actually hold, scaled to U100 units.
    ///
    /// - Parameter supportedBasalRates: `PumpManager.supportedBasalRates`, which starts at 0 on
    ///   pumps that allow a zero scheduled rate, so the first positive entry is the step.
    static func resolveBasal(supportedBasalRates: [Double], concentration: Decimal) -> Decimal {
        let step = supportedBasalRates.first(where: { $0 > 0 }).map { Decimal($0) } ?? basalFallback
        return step * concentration
    }
}
