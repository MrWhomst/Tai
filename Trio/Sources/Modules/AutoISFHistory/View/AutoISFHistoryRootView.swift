import CoreData
import Foundation
import SwiftDate
import SwiftUI
import Swinject

extension AutoISFHistory {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @Environment(\.horizontalSizeClass) var sizeClass
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @Environment(\.managedObjectContext) var context

        @State private var selectedEndTime = Date()
        @State private var selectedTimeIntervalIndex = 1 // Default to 2 hours
        @State private var timeIntervalOptions = []
        @State private var selectedEntry: AutoISFHistoryEntry? // Track selected entry
        @State private var isPopupPresented = false
        @State private var tapped: Bool = false

        private var color: LinearGradient {
            colorScheme == .dark ? LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.011, green: 0.058, blue: 0.109),
                    Color(red: 0.03921568627, green: 0.1333333333, blue: 0.2156862745)
                ]),
                startPoint: .bottom,
                endPoint: .top
            )
                :
                LinearGradient(gradient: Gradient(colors: [Color.gray.opacity(0.1)]), startPoint: .top, endPoint: .bottom)
        }

        private let itemFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return formatter
        }()

        private var glucoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal

            if state.units == .mmolL {
                formatter.maximumFractionDigits = 1
                formatter.minimumFractionDigits = 1
                formatter.roundingMode = .halfUp
            } else {
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        var body: some View {
            VStack(spacing: 0) {
                Text("autoISF calculations")
                    .font(.headline)
                    .foregroundColor(.uam)
                HStack {
                    CustomDateTimePicker(selection: $state.selectedEndTime, minuteInterval: 15)
                        .frame(height: 40)
                    Spacer()
                    Picker("", selection: $state.selectedTimeIntervalIndex) {
                        ForEach(0 ..< state.timeIntervalOptions.count, id: \.self) { index in
                            Text("\(state.timeIntervalOptions[index])h").tag(index)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                .padding()

                // Table headers with Grid
                VStack(spacing: 4) {
                    Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 4) {
                        GridRow {
                            Text("").gridCellColumns(2)

                            Text(String(localized: "Insulin", comment: "Label for Insulin section"))
                                .foregroundColor(.insulin)
                                .gridCellColumns(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(String(localized: "ISF factors", comment: "Label for ISF factors section"))
                                .foregroundColor(.uam)
                                .gridCellColumns(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GridRow {
                            Text(String(localized: "Time", comment: "Label for Time"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(minWidth: 40, alignment: .leading)

                            Text(String(localized: "BG", comment: "Label for BG"))
                                .foregroundColor(.loopGreen)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "SMB", comment: "Label for SMB"))
                                .foregroundColor(.insulin)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "req.", comment: "Label for req."))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            // Neutral on purpose: the values below take the hue of
                            // whichever factor won, so a fixed hue here would read
                            // as a claim about which one that is.
                            Text(String(localized: "final", comment: "Label for final"))
                                .bold()
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "acce", comment: "Label for acce"))
                                .foregroundColor(ISFFactor.acce.color)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "bg", comment: "Label for bg"))
                                .foregroundColor(ISFFactor.bg.color)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "pp", comment: "Label for pp"))
                                .foregroundColor(ISFFactor.pp.color)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(String(localized: "dura", comment: "Label for dura"))
                                .foregroundColor(ISFFactor.dura.color)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(state.autoISFEntries, id: \.self) { entry in
                                GridEntryRow(
                                    entry: entry,
                                    glucoseFormatter: glucoseFormatter,
                                    units: state.units
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    tapped = true
                                    selectedEntry = entry
                                    isPopupPresented = true
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !tapped {
                    HStack {
                        Image(systemName: "hand.tap.fill")
                        Text(String(
                            localized: "Tap an entry row for details.",
                            comment: "Text prompting user to tap an entry row for details"
                        ))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .padding()
                }
            }
            .font(.caption)
            .onAppear(perform: configureView)
            .navigationBarTitle("")
            .navigationBarItems(leading: Button(action: state.hideModal) {
                Text(String(localized: "Close", comment: "Close button label"))
                    .foregroundColor(Color.tabBar)
            })
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .overlay(
                popupView(), alignment: .bottom
            )
        }

        /// The four autoISF sub-factors, each with its own hue. `final` borrows the
        /// hue of whichever factor drove it (see `dominant`), so a glance down the
        /// final column shows which signal was in charge at any point in time.
        enum ISFFactor {
            case acce
            case bg
            case pp
            case dura

            /// `bg` and `pp` deliberately borrow the hues of the quantities they
            /// derive from — the BG value column (`loopGreen`) and the SMB column
            /// (`insulin`) — so a factor is visually tied to its input.
            var color: Color {
                switch self {
                case .acce: return .uam
                case .bg: return .loopGreen
                case .pp: return .insulin
                case .dura: return .zt
                }
            }

            /// `AutoISFAdjust` lifts by `max(dura, bg, acce, pp)` above target and
            /// brakes by `min(bg, acce)` below it — in both cases the deciding factor
            /// is the one furthest from the neutral 1.00. Ties keep the declaration
            /// order (acce, bg, pp, dura). All-neutral means autoISF did nothing.
            static func dominant(
                acce: Decimal?,
                bg: Decimal?,
                pp: Decimal?,
                dura: Decimal?
            ) -> ISFFactor? {
                let candidates: [(ISFFactor, Decimal)] = [
                    (.acce, acce ?? 1),
                    (.bg, bg ?? 1),
                    (.pp, pp ?? 1),
                    (.dura, dura ?? 1)
                ]
                guard let winner = candidates.max(by: { abs($0.1 - 1) < abs($1.1 - 1) }),
                      abs(winner.1 - 1) >= Decimal(0.005) // below display precision = neutral
                else { return nil }
                return winner.0
            }
        }

        private struct GridEntryRow: View {
            let entry: AutoISFHistoryEntry
            let glucoseFormatter: NumberFormatter
            let units: GlucoseUnits

            private let ratioFormatter: NumberFormatter = {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                return formatter
            }()

            private func formatRatio(_ decimal: Decimal?) -> String {
                guard let decimal = decimal else { return "0.00" }
                return ratioFormatter.string(from: decimal as NSDecimalNumber) ?? "0.00"
            }

            private func convertGlucose(_ value: Decimal, to units: GlucoseUnits) -> Double {
                switch units {
                case .mmolL:
                    return Double(value) * 0.0555
                case .mgdL:
                    return Double(value)
                }
            }

            private var dominantFactor: ISFFactor? {
                ISFFactor.dominant(
                    acce: entry.acce_ratio,
                    bg: entry.bg_ratio,
                    pp: entry.pp_ratio,
                    dura: entry.dura_ratio
                )
            }

            var body: some View {
                Grid(alignment: .leading, horizontalSpacing: 8) {
                    GridRow {
                        Text(Formatter.timeFormatter.string(from: entry.timestamp ?? Date()))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(minWidth: 40, alignment: .leading)

                        let displayGlucose = convertGlucose(entry.bg ?? 0, to: units)
                        Text(glucoseFormatter.string(from: NSNumber(value: displayGlucose)) ?? "")
                            .foregroundColor(.loopGreen)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text("\(entry.smb ?? 0)")
                            .foregroundColor(.insulin)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text("\(entry.insulin_req ?? 0)")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        // Bold on purpose — this is the applied result. Note it makes
                        // the hue read brighter here than the same color in the factor
                        // column it was taken from; that is the weight, not a tint.
                        Text(formatRatio(entry.autoISF_ratio))
                            .bold()
                            .foregroundColor(dominantFactor?.color ?? .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(formatRatio(entry.acce_ratio))
                            .foregroundColor(ISFFactor.acce.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(formatRatio(entry.bg_ratio))
                            .foregroundColor(ISFFactor.bg.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(formatRatio(entry.pp_ratio))
                            .foregroundColor(ISFFactor.pp.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(formatRatio(entry.dura_ratio))
                            .foregroundColor(ISFFactor.dura.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .background(Color.clear)
            }
        }

        private func convertGlucose(_ value: Decimal, to units: GlucoseUnits) -> Double {
            switch units {
            case .mmolL:
                return Double(value) * 0.0555
            case .mgdL:
                return Double(value)
            }
        }

        @ViewBuilder private func popupView() -> some View {
            if isPopupPresented, let entry = selectedEntry {
                VStack {
                    Spacer().frame(height: 200) // Adds spacing at the top

                    DetailPopupView(
                        entry: entry,
                        isPopupPresented: $isPopupPresented,
                        units: state.units,
                        maxIOB: state.maxIOB,
                        iobThresholdPercent: state.iobThresholdPercent,
                        entries: state.autoISFEntries,
                        selectedEntry: $selectedEntry,
                        moveToPreviousEntry: moveToPreviousEntry,
                        moveToNextEntry: moveToNextEntry
                    )
                    .transition(.move(edge: .top))
                    .animation(.easeInOut)
                }
                .frame(maxWidth: .infinity)
                .edgesIgnoringSafeArea(.top)
            }
        }

        // Get index of current entry
        private var currentIndex: Int? {
            state.autoISFEntries.firstIndex(where: { $0 == selectedEntry })
        }

        // Move to previous entry
        private func moveToPreviousEntry() {
            if let index = currentIndex, index > 0 {
                selectedEntry = state.autoISFEntries[index - 1]
            }
        }

        // Move to next entry
        private func moveToNextEntry() {
            if let index = currentIndex, index < state.autoISFEntries.count - 1 {
                selectedEntry = state.autoISFEntries[index + 1]
            }
        }
    }
}
