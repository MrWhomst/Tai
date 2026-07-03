import SwiftUI

struct SettingInputSection<VerboseHint: View>: View {
    enum SettingInputSectionType: Equatable {
        case decimal(String)
        case boolean
        case conditionalDecimal(String)

        static func == (lhs: SettingInputSectionType, rhs: SettingInputSectionType) -> Bool {
            switch (lhs, rhs) {
            case (.boolean, .boolean):
                return true
            case let (.decimal(lhsValue), .decimal(rhsValue)):
                return lhsValue == rhsValue
            case let (.conditionalDecimal(lhsValue), .conditionalDecimal(rhsValue)):
                return lhsValue == rhsValue
            default:
                return false
            }
        }
    }

    @Binding var decimalValue: Decimal
    @Binding var booleanValue: Bool
    @Binding var shouldDisplayHint: Bool
    @Binding var selectedVerboseHint: (any View)?

    var units: GlucoseUnits
    var type: SettingInputSectionType
    var label: String
    var conditionalLabel: String?
    var miniHint: String
    var verboseHint: VerboseHint
    var headerText: String?
    var footerText: String?
    var isToggleDisabled: Bool = false
    var miniHintColor: Color = .secondary
    /// When `true`, the label text is tinted with the accent color. Used by the profile draft
    /// editor to mark values that differ from the source profile.
    var isChanged: Bool = false
    /// When non-nil AND `isChanged` is true, a small circle-x button is shown next to the value
    /// that invokes this closure to reset the field to its source value.
    var onReset: (() -> Void)? = nil

    @ObservedObject private var pickerSettingsProvider = PickerSettingsProvider.shared
    @State private var displayPicker: Bool = false
    @State private var displayConditionalPicker: Bool = false

    var body: some View {
        Section(
            content: {
                VStack {
                    switch type {
                    case let .decimal(key):
                        if let setting = getPickerSetting(for: key) {
                            pickerView(
                                label: label,
                                displayPicker: $displayPicker,
                                setting: setting,
                                decimalValue: $decimalValue
                            )
                        }

                    case .boolean:
                        toggleView(label: label, isOn: $booleanValue)
                            .disabled(isToggleDisabled)

                    case let .conditionalDecimal(key):
                        VStack {
                            toggleView(label: label, isOn: $booleanValue)
                            if booleanValue, let setting = getPickerSetting(for: key) {
                                pickerView(
                                    label: conditionalLabel ?? label,
                                    displayPicker: $displayConditionalPicker,
                                    setting: setting,
                                    decimalValue: $decimalValue
                                )
                            }
                        }
                    }

                    hintSection(
                        miniHint: miniHint,
                        shouldDisplayHint: $shouldDisplayHint,
                        verboseHint: verboseHint,
                        miniHintColor: miniHintColor
                    )
                }
            },
            header: { headerText.map(Text.init) },
            footer: { footerText.map(Text.init) }
        )
        .settingsSearchTarget(label: label)
    }

    // Helper function to retrieve PickerSetting based on key
    private func getPickerSetting(for key: String) -> PickerSetting? {
        pickerSettingsProvider.pickerSetting(for: key)
    }

    private func pickerView(
        label: String,
        displayPicker: Binding<Bool>,
        setting: PickerSetting,
        decimalValue: Binding<Decimal>
    ) -> some View {
        VStack {
            HStack {
                Text(label)
                    .foregroundColor(isChanged ? .accentColor : .primary)
                Spacer()
                if isChanged, let onReset = onReset {
                    Button(action: onReset) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                displayText(for: setting, decimalValue: decimalValue.wrappedValue)
                    .foregroundColor(!displayPicker.wrappedValue ? .primary : .accentColor)
                    .onTapGesture {
                        displayPicker.wrappedValue.toggle()
                    }
            }.padding(.top)

            if displayPicker.wrappedValue {
                Picker(selection: decimalValue, label: Text(label)) {
                    ForEach(pickerSettingsProvider.generatePickerValues(from: setting, units: self.units), id: \.self) { value in
                        displayText(for: setting, decimalValue: value).tag(value)
                    }
                }
                .pickerStyle(WheelPickerStyle())
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func displayText(for setting: PickerSetting, decimalValue: Decimal) -> Text {
        switch setting.type {
        case .glucose:
            let displayValue = units == .mmolL ? decimalValue.asMmolL : decimalValue
            return Text("\(displayValue.description) \(units.rawValue)")
        case .factor:
            return Text("\(decimalValue * 100) \(String(localized: "%", comment: "Percentage symbol"))")
        case .factorRaw:
            return Text("\(decimalValue)")
        case .insulinUnit:
            return Text("\(decimalValue) \(String(localized: "U", comment: "Insulin unit abbreviation"))")
        case .insulinUnitPerHour:
            return Text("\(decimalValue) \(String(localized: "U/hr", comment: "Insulin unit per hour abbreviation"))")
        case .gram:
            return Text("\(decimalValue) \(String(localized: "g", comment: "Gram abbreviation"))")
        case .minute:
            return Text("\(decimalValue) \(String(localized: "min", comment: "Minutes abbreviation"))")
        case .hour:
            return Text("\(decimalValue) \(String(localized: "hr", comment: "Hours abbreviation"))")
        case .percent:
            return Text("\(decimalValue) \(String(localized: "%", comment: "Percentage symbol"))")
        }
    }

    private func toggleView(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Toggle(isOn: isOn) {
                Text(label)
                    .foregroundColor(isChanged ? .accentColor : .primary)
            }
            if isChanged, let onReset = onReset {
                Button(action: onReset) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }.padding(.top)
    }

    public func hintSection(
        miniHint: String,
        shouldDisplayHint: Binding<Bool>,
        verboseHint: VerboseHint,
        miniHintColor: Color = .secondary
    ) -> some View {
        HStack(alignment: .center) {
            Text(miniHint)
                .font(.footnote)
                .foregroundColor(miniHintColor)
                .lineLimit(nil)
            Spacer()
            Button(action: {
                shouldDisplayHint.wrappedValue.toggle()
                selectedVerboseHint = shouldDisplayHint.wrappedValue ? verboseHint : nil
            }) {
                HStack {
                    Image(systemName: "questionmark.circle")
                }
            }
            .buttonStyle(BorderlessButtonStyle())
        }.padding(.vertical)
    }
}
