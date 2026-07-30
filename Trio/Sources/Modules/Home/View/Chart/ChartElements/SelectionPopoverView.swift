import Charts
import Foundation
import SwiftUI

/// Color of the selection marker/readout for a glucose value. Shared by the popover card
/// and the shell's selection overlay dot.
func selectionMarkColor(
    for glucose: GlucoseStored,
    highGlucose: Decimal,
    lowGlucose: Decimal,
    currentGlucoseTarget: Decimal,
    glucoseColorScheme: GlucoseColorScheme
) -> Color {
    let hardCodedLow = Decimal(55)
    let hardCodedHigh = Decimal(220)
    let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

    return Trio.getDynamicGlucoseColor(
        glucoseValue: Decimal(glucose.glucose),
        highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
        lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
        targetGlucose: currentGlucoseTarget,
        glucoseColorScheme: glucoseColorScheme
    )
}

/// The selection detail card. Plain SwiftUI (no longer `ChartContent`): it is rendered by
/// the shell's selection overlay in a fixed slot, so it can neither be clipped by the
/// viewport nor force a canvas re-layout while scrubbing.
struct SelectionPopoverView: View {
    let selectedGlucose: GlucoseStored
    let selectedIOBValue: OrefDetermination?
    let selectedCOBValue: OrefDetermination?
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let isSmoothingEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var glucoseToDisplay: Decimal {
        units == .mgdL ? Decimal(selectedGlucose.glucose) : Decimal(selectedGlucose.glucose).asMmolL
    }

    private var pointMarkColor: Color {
        selectionMarkColor(
            for: selectedGlucose,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            currentGlucoseTarget: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    @ViewBuilder var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "clock")
                Text(selectedGlucose.date?.formatted(.dateTime.hour().minute(.twoDigits)) ?? "")
                    .font(.body).bold()
            }
            .font(.body).padding(.bottom, 2)

            HStack {
                Text("CGM: ") + Text(glucoseToDisplay.description).bold() + Text(" \(units.rawValue)")
            }
            .foregroundStyle(pointMarkColor)
            .font(.body)
            .shadow(color: colorScheme == .light ? Color.black.opacity(0.5) : Color.clear, radius: 1, x: 1, y: 1)

            if isSmoothingEnabled, let smoothedGlucose = selectedGlucose.smoothedGlucose {
                var smoothedGlucoseToDisplay: Decimal {
                    units == .mgdL ? smoothedGlucose.decimalValue : smoothedGlucose.decimalValue.asMmolL
                }
                HStack {
                    Image(systemName: "sparkles")
                    Text(smoothedGlucoseToDisplay.description) + Text(" \(units.rawValue)")
                }.font(.body)
            }

            if let selectedIOBValue, let iob = selectedIOBValue.iob {
                HStack {
                    Image(systemName: "drop.circle")
                        .frame(width: 15)
                    Text(Formatter.bolusFormatter.string(from: iob) ?? "")
                        .bold()
                        + Text(String(localized: " U", comment: "Insulin unit"))
                }
                .foregroundStyle(Color.insulin).font(.body)
                .padding(.top, 4)
            }

            if let selectedCOBValue {
                HStack {
                    Image("premeal")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundColor(.orange)
                    Text(Formatter.integerFormatter.string(from: selectedCOBValue.cob as NSNumber) ?? "")
                        .bold()
                        + Text(String(localized: " g", comment: "gram of carbs"))
                }
                .foregroundStyle(Color.orange).font(.body)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5).opacity(0.95))
                .shadow(color: Color.secondary, radius: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary, lineWidth: 2)
                )
        }
    }
}
