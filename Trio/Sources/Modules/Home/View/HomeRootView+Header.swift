import CoreData
import SwiftUI

// MARK: - Zone B: header (left info panel / glucose bobble / loop status)

extension Home.RootView {
    var cgmSelectionButtons: some View {
        ForEach(cgmOptions, id: \.name) { option in
            if let cgm = state.listOfCGM.first(where: option.predicate) {
                Button(option.name) {
                    state.addCGM(cgm: cgm)
                }
            }
        }
    }

    var glucoseView: some View {
        CurrentGlucoseView(
            concentration: state.concentration,
            hideInsulinBadge: state.hideInsulinBadge,
            timerDate: state.timerDate,
            units: state.units,
            alarm: state.alarm,
            lowGlucose: state.lowGlucose,
            highGlucose: state.highGlucose,
            cgmAvailable: state.cgmAvailable,
            currentGlucoseTarget: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme,
            glucose: state.latestTwoGlucoseValues,
            cgmProgress: state.cgmProgressHighlight,
            cgmStatus: state.cgmDisplayState,
            cgmSensorExpiresAt: state.cgmSensorExpiresAt,
            cgmWarmupEndsAt: state.cgmWarmupEndsAt
        )
        .onTapGesture {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }
        .onLongPressGesture {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()
            showSnoozeSheet = true
        }
    }

    @ViewBuilder func rightHeaderPanel() -> some View {
        VStack(alignment: .trailing, spacing: 15) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16))
                    .foregroundColor(.loopGreen)
                let isfValue = state.enactedAndNonEnactedDeterminations.first?.insulinSensitivity ?? NSDecimalNumber.zero
                let isfValueDecimal = isfValue.decimalValue
                let convertedISF = state.units == .mgdL ? isfValueDecimal.description : isfValueDecimal
                    .formattedAsMmolL
                Text(convertedISF)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
//                    Text("\(state.units.rawValue)/U")
//                        .font(.system(size: 12, design: .rounded))
            }

            /// eventualBG string
            if let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG {
                let eventualGlucose = eventualBG as Decimal
                HStack {
                    Text(
                        "⇢"
                    ).font(.system(size: 18, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(state.units == .mgdL ? eventualGlucose.description : eventualGlucose.formattedAsMmolL)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            } else {
                HStack {
                    Text("⇢")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("--")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            /// Loop view at bottomLeading
            /// Loop view at bottomLeading
            LoopView(
                closedLoop: state.closedLoop,
                timerDate: state.timerDate,
                isLooping: state.isLooping,
                lastLoopDate: state.lastLoopDate,
                manualTempBasal: state.manualTempBasal,
                determination: state.determinationsFromPersistence
            )
            .onTapGesture {
                state.isStatusPopupPresented.toggle()
            }
            .onLongPressGesture {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                state.runLoop()
            }
        }
    }

    var basalString: String? {
        var rate: NSNumber = 0
        var manualBasalString = ""

        guard let apsManager = state.apsManager else {
            return nil
        }

        if apsManager.isScheduledBasal == true {
            guard let scheduledRate = scheduledBasalDeliveryRate(at: Date()) else {
                return nil
            }
            rate = scheduledRate
        } else {
            guard let lastTempBasal = state.tempBasals.last?.tempBasal, let tempRate = lastTempBasal.rate else {
                return nil
            }
            if apsManager.isManualTempBasal {
                manualBasalString = String(
                    localized: " ⚠️",
                    comment: "Manual Temp basal"
                )
            }
            rate = tempRate
        }
        let rateString = Formatter.insulinFormatterToIncrement(for: state.bolusIncrement)
            .string(from: rate as NSNumber) ?? "0"
        return rateString + String(localized: " U/hr", comment: "Unit per hour with space") +
            manualBasalString
    }

    // Returns the scheduled basal rate for the current time based on the saved basal scheduled.
    // Would be better if in the future BasalDeliveryStatus could be updated to include this info.
    func scheduledBasalDeliveryRate(at when: Date) -> NSNumber? {
        let calendar = Calendar(identifier: .gregorian)
        // calendar.timeZone = timeZone /// should come from pumpManager in case it's different!

        let hours = calendar.component(.hour, from: when)
        let minutes = calendar.component(.minute, from: when)
        let totalMinutes = hours * 60 + minutes

        if let rate = findBasalRateForOffset(for: totalMinutes, in: state.basalProfile) {
            return NSDecimalNumber(decimal: rate)
        }
        return nil
    }

    @ViewBuilder func leftHeaderPanel() -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "drop.circle")
                    .font(.system(size: 16))
                    .foregroundColor(.insulin)
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits
                            .string(from: state.currentIOB as NSNumber) ?? "0"
                    ) +
                        String(localized: " U", comment: "Insulin unit")
                )
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
//                    InsulinConcentrationBadge(concentration: 1)
            }
            HStack {
                Image("premeal")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .foregroundColor(.loopYellow)
                    .padding(.leading, 3)
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits.string(
                            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                        ) ?? "0"
                    ) +
                        String(localized: " g", comment: "gram of carbs")
                )
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            }
            HStack {
                /// Only display the insulin delivery rate info if the pump is not
                /// suspended and is available (e.g., pod is paired & not faulted).
                if let apsManager = state.apsManager {
                    let pumpAvailable = apsManager.isScheduledBasal != nil
                    if apsManager.isSuspended {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 16))
                            .rotationEffect(Angle(degrees: 180))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.insulinTintColor.opacity(0.9), .insulinTintColor.opacity(0.2)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Text("0" + String(localized: " U/hr", comment: "Unit per hour with space"))
                            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                            .foregroundColor(.orange)
                    } else if pumpAvailable {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 16))
                            .rotationEffect(Angle(degrees: 180))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.insulinTintColor.opacity(0.9), .insulinTintColor.opacity(0.2)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        if let basalString = self.basalString {
                            /// Adjust opacity when displaying a scheduled basal rate
                            let opacity = apsManager.isScheduledBasal == true ? 0.6 : 1.0
                            if basalString.count > 5 {
                                Text(basalString)
                                    .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .truncationMode(.tail)
                                    .allowsTightening(true)
                                    .opacity(opacity)
                            } else {
                                // Short strings can just display normally
                                Text(basalString)
                                    .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                                    .opacity(opacity)
                            }
                        } else {
                            Text("No Data")
                                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                        }
                    }
                }
            }
        }
    }
}
