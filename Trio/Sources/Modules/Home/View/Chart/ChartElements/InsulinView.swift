import Charts
import Foundation
import SwiftUI

struct InsulinView: ChartContent {
    let glucoseData: [GlucoseStored]
    let insulinData: [PumpEventStored]
    let units: GlucoseUnits
    let bolusIncrement: Decimal
    let useBars: Bool
    let screenHours: Int16
    let bolusDisplayThreshold: BolusDisplayThreshold

    /// Scaling reference for bar height: max bolus amount across the visible insulin data.
    /// Floor of 1 keeps short windows from blowing tiny SMBs up to full bar height.
    private var maxBolusValue: Decimal {
        let amounts = insulinData.compactMap { $0.bolus?.amount?.decimalValue }
        return amounts.max() ?? 1
    }

    var body: some ChartContent {
        drawBoluses()
        drawSMBs()
        drawExternals()
    }

    private func drawBoluses() -> some ChartContent {
        ForEach(insulinData) { insulin in
            // Safely unwrap the optional bolus
            if let bolus = insulin.bolus, bolus.isSMB == false, bolus.isExternal == false {
                let amount = bolus.amount ?? 0 as NSDecimalNumber
                let bolusDate = insulin.timestamp ?? Date()

                if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                    glucoseValues: glucoseData,
                    time: bolusDate.timeIntervalSince1970
                )?.glucose {
                    let baseY = units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL
                    let amountDecimal = amount.decimalValue
                    let showLabel = amountDecimal >= bolusDisplayThreshold.rawValue
                    let label = showLabel ? Formatter.bolusFormatterToIncrement(for: bolusIncrement)
                        .string(from: amount) ?? "" : ""

                    if useBars {
                        // Bar mode: anchor at curve, fixed pixel gap. Peak-label overlap is resolved by
                        // LabelPlacement on the peak labels rather than by shifting the bar.
                        bolusBarMark(
                            date: bolusDate,
                            yPosition: baseY,
                            amount: amountDecimal,
                            barWidth: MainChartHelper.bolusBarWidth(
                                amount: amountDecimal,
                                minimumSMB: MainChartHelper.Config.smbWidthThreshold,
                                screenHours: screenHours
                            ),
                            label: label,
                            color: Color(red: 0.05, green: 0.32, blue: 0.62)
                        )
                    } else {
                        // Anchor at curve. Peak labels are fixed-position too, so the
                        // legacy peak-collision shift is no longer needed.
                        let yPosition = baseY
                        let size = (sqrt(CGFloat(amount) / .pi) * MainChartHelper.Config.bolusScale * 2)

                        PointMark(
                            x: .value("Time", bolusDate, unit: .second),
                            y: .value("Value", yPosition)
                        )
                        .symbol {
                            Image(systemName: "circle.fill").font(.system(size: size)).foregroundStyle(Color.teal)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: 0.4)
                                )
                        }
                        .annotation(position: .top, spacing: 2) {
                            Text(label)
                                .font(.caption2)
                                .fixedSize()
                                .rotationEffect(.degrees(-90))
                                .frame(width: 12, height: 22)
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
            }
        }
    }

    private func drawSMBs() -> some ChartContent {
        ForEach(insulinData) { insulin in
            // Safely unwrap the optional bolus
            if let bolus = insulin.bolus, bolus.isSMB == true {
                let amount = bolus.amount ?? 0 as NSDecimalNumber
                let bolusDate = insulin.timestamp ?? Date()

                if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                    glucoseValues: glucoseData,
                    time: bolusDate.timeIntervalSince1970
                )?.glucose {
                    let amountDecimal = amount.decimalValue
                    let showLabel = amountDecimal >= bolusDisplayThreshold.rawValue
                    let label = showLabel ? Formatter.bolusFormatterToIncrement(for: bolusIncrement)
                        .string(from: amount) ?? "" : ""

                    if useBars {
                        // Bar mode: anchor SMBs at curve, fixed pixel gap. Peak-label collision is
                        // handled by LabelPlacement on the peak labels.
                        let baseY = units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL

                        bolusBarMark(
                            date: bolusDate,
                            yPosition: baseY,
                            amount: amountDecimal,
                            barWidth: MainChartHelper.bolusBarWidth(
                                amount: amountDecimal,
                                minimumSMB: MainChartHelper.Config.smbWidthThreshold,
                                screenHours: screenHours
                            ),
                            label: label,
                            color: Color.insulin
                        )
                    } else {
                        let size = (
                            MainChartHelper.Config.bolusSize + CGFloat(truncating: amount) * MainChartHelper.Config
                                .bolusScale
                        )
                        // Fixed offset above the curve; no peak-collision shift needed.
                        let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) + MainChartHelper
                            .bolusOffset(units: units)

                        PointMark(
                            x: .value("Time", bolusDate, unit: .second),
                            y: .value("Value", yPosition)
                        )
                        .symbol {
                            ZStack {
                                Image(systemName: "arrowtriangle.down")
                                    .font(.system(size: size + 3))
                                    .foregroundStyle(Color.primary)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: size))
                                    .foregroundStyle(Color.insulin)
                            }
                        }
                        .annotation(position: .top, spacing: 2) {
                            Text(label)
                                .font(.caption2)
                                .fixedSize()
                                .rotationEffect(.degrees(-90))
                                .frame(width: 12, height: 22)
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
            }
        }
    }

    private func drawExternals() -> some ChartContent {
        ForEach(insulinData.filter { $0.bolus?.isExternal == true }) { insulin in
            let amount = insulin.bolus?.amount ?? 0 as NSDecimalNumber
            let bolusDate = insulin.timestamp ?? Date()

            if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: bolusDate.timeIntervalSince1970
            )?.glucose {
                let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) + MainChartHelper
                    .bolusOffset(units: units) * 2
                // Relative sizing: scale based on ratio to max bolus, similar to bar height scaling
                let amountDecimal = amount.decimalValue
                let ratio = CGFloat(truncating: NSDecimalNumber(decimal: amountDecimal / maxBolusValue))
                let size = (sqrt(ratio / .pi) * MainChartHelper.Config.bolusScale * 2 + 8)

                PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol {
                    ZStack {
                        Image(systemName: "rhombus")
                            .font(.system(size: size + 2))
                            .foregroundStyle(Color.primary)
                        Image(systemName: "rhombus.fill")
                            .font(.system(size: size))
                            .foregroundStyle(Color.purple)
                    }
                }
                .annotation(position: .top, spacing: 2) {
                    Text(Formatter.bolusFormatterToIncrement(for: bolusIncrement).string(from: amount) ?? "")
                        .font(.caption2)
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 12, height: 22)
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    private func bolusBarMark(
        date: Date,
        yPosition: Decimal,
        amount: Decimal,
        barWidth: CGFloat,
        label: String,
        color: Color
    ) -> some ChartContent {
        let height = MainChartHelper.bolusBarHeight(amount: amount, maxAmount: maxBolusValue)

        return PointMark(
            x: .value("Time", date, unit: .second),
            y: .value("Value", yPosition)
        )
        .symbol { Color.clear.frame(width: 0, height: 0) }
        .annotation(position: .top, alignment: .center, spacing: MainChartHelper.Config.bolusBarSpacing) {
            VStack(spacing: MainChartHelper.Config.bolusAnnotationSpacing) {
                Text(label)
                    .font(.caption2)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: 22)
                    .foregroundStyle(Color.primary)
                DownArrowBarShape()
                    .fill(color)
                    .overlay(
                        DownArrowBarShape().stroke(Color.primary, lineWidth: 0.4)
                    )
                    .frame(width: barWidth, height: height)
            }
        }
    }
}
