import CoreData
import SwiftUI

// MARK: - Zone E: bottom controls (adjustment panel / bolus progress / stats + info buttons)

extension Home.RootView {
    var bolusProgressFormatter: NumberFormatter {
        let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
        case 0.1: 1
        case 0.025: 3
        default: 2
        }

        let formatter = NumberFormatter()
        let bolusIncrement = state.bolusIncrement
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximumFractionDigits = Decimal.maxFractionDigits(for: bolusIncrement)
        formatter.minimumFractionDigits = 1
        formatter.allowsFloats = true
        formatter.roundingIncrement = Double(bolusIncrement) as NSNumber
        return formatter
    }

    private var fetchedTargetFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if state.units == .mmolL {
            formatter.maximumFractionDigits = 1
        } else { formatter.maximumFractionDigits = 0 }
        return formatter
    }

    var overrideString: String? {
        guard let latestOverride = latestOverride.first else {
            return nil
        }

        guard let settingsManager = state.settingsManager else {
            return nil
        }

        let percent = latestOverride.percentage
        let percentString = percent == 100 ? "" : "\(percent.formatted(.number)) %"

        let unit = state.units
        var target = (latestOverride.target ?? 0) as Decimal
        target = unit == .mmolL ? target.asMmolL : target

        var targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " + unit
            .rawValue
        if tempTargetString != nil {
            targetString = ""
        }

        let duration = latestOverride.duration ?? 0
        let addedMinutes = Int(truncating: duration)
        let date = latestOverride.date ?? Date()
        let newDuration = max(
            Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
            0
        )
        let indefinite = latestOverride.indefinite
        var durationString = ""

        if !indefinite {
            if newDuration >= 1 {
                durationString = formatHrMin(Int(newDuration))
            } else if newDuration > 0 {
                durationString = "\(Int(newDuration * 60)) s"

            } else {
                /// Do not show the Override anymore
                Task {
                    guard let objectID = self.latestOverride.first?.objectID else { return }
                    await state.cancelOverride(withID: objectID)
                }
            }
        }

        let smbScheduleString = latestOverride
            .smbIsScheduledOff && ((latestOverride.start?.stringValue ?? "") != (latestOverride.end?.stringValue ?? ""))
            ? " \(formatTimeRange(start: latestOverride.start?.stringValue, end: latestOverride.end?.stringValue))"
            : ""

        let smbToggleString = latestOverride.smbIsOff || latestOverride
            .smbIsScheduledOff ? String(
                localized: "SMBs Off\(smbScheduleString)",
                comment: "Override subtitle fragment on Home showing that SMBs are disabled — interpolated value is an optional time-range like ' 08:00-10:00'"
            ) : ""

        var smbMinuteString: String = ""
        var uamMinuteString: String = ""

        if !latestOverride.smbIsOff, latestOverride.advancedSettings {
            if let smbMinutes = latestOverride.smbMinutes,
               smbMinutes.decimalValue != settingsManager.preferences.maxSMBBasalMinutes
            {
                smbMinuteString = "SMB\u{00A0}\(smbMinutes)\u{00A0}" +
                    String(localized: "m", comment: "Abbreviation for Minutes")
            }

            if let uamMinutes = latestOverride.uamMinutes,
               uamMinutes.decimalValue != settingsManager.preferences.maxUAMSMBBasalMinutes
            {
                uamMinuteString = "UAM\u{00A0}\(uamMinutes)\u{00A0}" +
                    String(localized: "m", comment: "Abbreviation for Minutes")
            }
        }

        let components = [durationString, percentString, targetString, smbToggleString, smbMinuteString, uamMinuteString]
            .filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    var tempTargetString: String? {
        guard let latestTempTarget = latestTempTarget.first else {
            return nil
        }
        let duration = latestTempTarget.duration
        let addedMinutes = Int(truncating: duration ?? 0)
        let date = latestTempTarget.date ?? Date()
        let newDuration = max(
            Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
            0
        )
        var durationString = ""
        var percentageString = ""
        var target = (latestTempTarget.target ?? 100) as Decimal
        // Use TempTargetCalculations to get effective HBT (handles both custom and auto-adjusted standard TT)
        let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
            tempTargetHalfBasalTarget: latestTempTarget.halfBasalTarget?.decimalValue,
            settingHalfBasalTarget: state.settingHalfBasalTarget,
            target: target,
            autosensMax: state.autosensMax
        ) ?? state.settingHalfBasalTarget
        var showPercentage = false
        if target > 100, state.highTTraisesSens { showPercentage = true }
        if target < 100, state.lowTTlowersSens, state.autosensMax > 1 { showPercentage = true }
        if showPercentage {
            percentageString =
                " \(Int(TempTargetCalculations.computeAdjustedPercentage(halfBasalTarget: effectiveHBT, target: target, autosensMax: state.autosensMax)))%"
        }
        target = state.units == .mmolL ? target.asMmolL : target
        let targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " +
            state.units.rawValue + percentageString

        if newDuration >= 1 {
            durationString =
                "\(newDuration.formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) min"
        } else if newDuration > 0 {
            durationString =
                "\((newDuration * 60).formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) s"
        } else {
            /// Do not show the Temp Target anymore
            Task {
                guard let objectID = self.latestTempTarget.first?.objectID else { return }
                await state.cancelTempTarget(withID: objectID)
            }
        }

        let components = [targetString, durationString].filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    /// Zone E: fixed-height bottom slot. Shows the bolus progress while a bolus
    /// runs, otherwise the adjustments panel; Tai's stats and legend buttons sit
    /// vertically stacked at the trailing edge.
    @ViewBuilder func bottomControls() -> some View {
        HStack(spacing: 8) {
            Group {
                if let progress = state.bolusProgress {
                    bolusProgressView(progress)
                } else {
                    adjustmentView()
                }
            }
            .frame(maxWidth: .infinity)

            sideButtons
        }
        .frame(height: HomeLayout.bottomPanelHeight)
        .padding(.horizontal, HomeLayout.bottomPanelHorizontalPadding)
        .padding(.top, HomeLayout.bottomZoneTopPadding)
        .padding(.bottom, HomeLayout.bottomZoneBottomPadding)
    }

    /// Stats and chart-legend circle buttons, stacked at the right edge of
    /// Zone E — pinned to the panel's top and bottom edges.
    var sideButtons: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "chart.bar.xaxis.ascending.badge.clock")
                .font(.system(size: 11))
                .symbolRenderingMode(.palette)
                .scaleEffect(x: -1)
                .foregroundStyle(
                    Color.secondary,
                    TaiStyle.linearGradient(
                        startPoint: .trailing, endPoint: .leading
                    )
                )
                .frame(width: 20, height: 20)
                .background(
                    colorScheme == .dark ? Color(red: 0.1176470588, green: 0.2352941176, blue: 0.3725490196) :
                        Color.white
                )
                .clipShape(Circle())
                .contentShape(Circle())
                .onTapGesture {
                    appState.statSelectedViewType = .glucose
                    appState.statSelectedInsulinTimeInterval = .day
                    state.showModal(for: .statistics)
                }

            Spacer(minLength: 0)

            Button(action: {
                state.isLegendPresented.toggle()
            }) {
                Image(systemName: "info")
                    .font(.system(size: 11))
                    .foregroundColor(colorScheme == .dark ? Color.white : Color.black).opacity(0.9)
                    .frame(width: 20, height: 20)
                    .background(
                        colorScheme == .dark ? Color(red: 0.1176470588, green: 0.2352941176, blue: 0.3725490196) :
                            Color.white
                    )
                    .clipShape(Circle())
            }

            Spacer(minLength: 0)
        }
        // Fill the Zone E slot so the Spacer pins the buttons to its edges.
        .frame(maxHeight: .infinity)
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.75 : 0.33),
            radius: colorScheme == .dark ? 5 : 3
        )
    }

    @ViewBuilder func adjustmentsOverrideView(_ overrideString: String) -> some View {
        HStack {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.title2)
                .foregroundStyle(Color.primary, Color.purple)
            VStack(alignment: .leading) {
                Text(latestOverride.first?.name ?? String(
                    localized: "Custom Override",
                    comment: "Fallback name on Home adjustments banner for an active override without a name"
                ))
                    .font(.subheadline)
                    .frame(alignment: .leading)

                Text(overrideString)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTab = 3
        }
    }

    @ViewBuilder func adjustmentsTempTargetView(_ tempTargetString: String) -> some View {
        HStack {
            let targetValue = latestTempTarget.first?.target?.doubleValue ?? 0.0
            let rotationValue: Double = targetValue < 100 ? 180 : 0
            Image(systemName: "arrow.up.circle.badge.clock")
                .rotationEffect(.degrees(rotationValue))
                .font(.system(size: 22))
                .foregroundStyle(Color.primary, Color.loopGreen)
            VStack(alignment: .leading) {
                Text(latestTempTarget.first?.name ?? String(
                    localized: "Temp Target",
                    comment: "Fallback name on Home adjustments banner for an active temp target without a name"
                ))
                    .font(.subheadline)
                    .frame(alignment: .leading)
                Text(tempTargetString)
                    .font(.caption)
                    .frame(alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTab = 3
        }
    }

    @ViewBuilder func adjustmentsProfileView(_ profile: ProfileStored) -> some View {
        HStack {
            if profile.expiresAt != nil {
                Image(systemName: "person.2.arrow.trianglehead.counterclockwise")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.primary, Color.blue)
            } else {
                Image(systemName: "person.2", variableValue: 0.58)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.blue, Color.white, Color.white)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.blue, lineWidth: 1.5)
                    )
            }
            HStack(spacing: 6) {
                Text(profile.name ?? String(
                    localized: "Active Profile",
                    comment: "Fallback name on Home adjustments banner for the active profile when it has no name set"
                ))
                    .font(.subheadline)
                let subtitle = profileSubtitle(profile, now: state.timerDate)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            // Profiles live in the Adjustments tab (tag 3) as the third sub-tab next
            // to Overrides and Temp Targets. We can't reach AdjustmentsRootView's local
            // tab state directly, so we leave a flag in UserDefaults that the view
            // consumes on its next .onAppear.
            UserDefaults.standard.set(true, forKey: Adjustments.pendingProfilesTabKey)
            selectedTab = 3
        }
    }

    /// Subtitle is recomputed against `state.timerDate` — the 5-second tick from
    /// HomeStateModel — so the countdown stays live without an ad-hoc timer.
    /// Same mechanism PumpView / LoopView use for their remaining-time displays.
    private func profileSubtitle(_ profile: ProfileStored, now: Date) -> String {
        var parts: [String] = []
        if let expires = profile.expiresAt {
            let minutesLeft = Int(expires.timeIntervalSince(now) / 60)
            let countdown = minutesLeft > 0 ? formatHrMin(minutesLeft) : String(
                localized: "Expiring",
                comment: "Countdown text on Home profile banner when less than a minute of a timed activation remains"
            )
            parts.append(countdown)
        }
        parts += ProfileSummaryLabel.strings(
            appliedPercent: profile.appliedPercent?.decimalValue,
            dailyBasalRate: profile.therapy?.basalProfile.totalDailyBasal,
            tuning: profileTuning(for: profile)
        )
        return parts.joined(separator: " · ")
    }

    /// Compares the profile's current prefs + glucose targets against its source to build
    /// the standard tuning badge. Returns `.none` if no source linkage exists.
    private func profileTuning(for profile: ProfileStored) -> ProfileSummaryLabel.Tuning {
        guard let sourceID = profile.sourceProfileID,
              let context = profile.managedObjectContext
        else { return .none }
        let req = ProfileStored.fetch(.profileByID(sourceID), fetchLimit: 1)
        guard let source = try? context.fetch(req).first else { return .none }
        let prefs: Bool = {
            guard let sp = source.preferences, let pp = profile.preferences else { return false }
            return pp != sp
        }()
        let targets: Bool = {
            guard let st = source.therapy?.bgTargets, let pt = profile.therapy?.bgTargets else { return false }
            return pt.targets != st.targets
        }()
        return ProfileSummaryLabel.Tuning(preferencesTuned: prefs, targetsTuned: targets)
    }

    @ViewBuilder func adjustmentsRevertProfileView() -> some View {
        Image(systemName: "xmark.app")
            .font(.system(size: 24))
            .foregroundStyle(Color.primary, Color.blue)
            .confirmationDialog(
                "Revert to previous profile?",
                isPresented: $isConfirmRevertProfilePresented,
                titleVisibility: .visible
            ) {
                Button("Revert", role: .destructive) {
                    Task { await state.revertActiveProfile() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onTapGesture {
                isConfirmRevertProfilePresented = true
            }
    }

    @ViewBuilder func adjustmentsCancelView(_ cancelAction: @escaping () -> Void) -> some View {
        Image(systemName: "xmark.app")
            .font(.system(size: 24))
            .foregroundStyle(
                Color.loopGreen,
                Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569)
            )
            .onTapGesture {
                cancelAction()
            }
    }

    @ViewBuilder func adjustmentsCancelTempTargetView() -> some View {
        Image(systemName: "xmark.app")
            .font(.system(size: 24))
            .foregroundStyle(Color.primary, Color.loopGreen)
            .confirmationDialog(
                "Stop the Temp Target \"\(latestTempTarget.first?.name ?? "")\"?",
                isPresented: $isConfirmStopTempTargetShown,
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    Task {
                        guard let objectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: objectID)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onTapGesture {
                if !latestTempTarget.isEmpty {
                    isConfirmStopTempTargetShown = true
                }
            }
    }

    @ViewBuilder func adjustmentsCancelOverrideView() -> some View {
        Image(systemName: "xmark.app")
            .font(.system(size: 24))
            .foregroundStyle(Color.primary, Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569))
            .confirmationDialog(
                "Stop the Override \"\(latestOverride.first?.name ?? "")\"?",
                isPresented: $isConfirmStopOverridePresented,
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    Task {
                        guard let objectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: objectID)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onTapGesture {
                if !latestOverride.isEmpty {
                    isConfirmStopOverridePresented = true
                }
            }
    }

    @ViewBuilder func noActiveAdjustmentsView() -> some View {
        Group {
            VStack {
                Text("No Active Adjustment")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Profile at 100 %")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, 10)

            Spacer()

            /// to ensure the same position....
            Image(systemName: "xmark.app")
                .font(.title)
                // clear color for the icon
                .foregroundStyle(Color.clear)
        }.onTapGesture {
            selectedTab = 3
        }
    }

    @ViewBuilder func adjustmentView() -> some View {
//            let background = colorScheme == .dark ? Material.ultraThinMaterial.opacity(0.5) : Color.black.opacity(0.2)

        let profileToShow: ProfileStored? = {
            guard overrideString == nil, tempTargetString == nil else { return nil }
            guard profilesForCount.count > 1 else { return nil }
            return activeProfile.first
        }()

        ZStack {
            /// rectangle as background
            RoundedRectangle(cornerRadius: 15)
                .fill(
                    (overrideString != nil || tempTargetString != nil || profileToShow != nil) ?
                        (
                            colorScheme == .dark ?
                                Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745) :
                                Color.insulin.opacity(0.1)
                        ) : Color.clear // Use clear and add the Material in the background
                )
                .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.35 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .frame(height: HomeLayout.bottomPanelHeight)
                .shadow(
                    color: (overrideString != nil || tempTargetString != nil || profileToShow != nil) ?
                        (
                            colorScheme == .dark ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706) :
                                Color.black.opacity(0.33)
                        ) : Color.clear,
                    radius: 3
                )
            HStack {
                if let overrideString = overrideString, let tempTargetString = tempTargetString {
                    HStack {
                        adjustmentsOverrideView(overrideString)

                        Spacer()

                        Divider()
                            .frame(height: HomeLayout.bottomPanelHeight - 16)
                            .padding(.horizontal, 2)

                        adjustmentsTempTargetView(tempTargetString)

                        Spacer()

                        adjustmentsCancelView({
                            if !latestTempTarget.isEmpty, !latestOverride.isEmpty {
                                showCancelConfirmDialog = true
                            } else if !latestOverride.isEmpty {
                                showCancelAlert = true
                            } else if !latestTempTarget.isEmpty {
                                showCancelAlert = true
                            }
                        })
                    }
                } else if let overrideString = overrideString {
                    adjustmentsOverrideView(overrideString)
                    Spacer()
                    adjustmentsCancelOverrideView()

                } else if let tempTargetString = tempTargetString {
                    HStack {
                        adjustmentsTempTargetView(tempTargetString)
                        Spacer()
                        adjustmentsCancelTempTargetView()
                    }
                } else if let profile = profileToShow {
                    HStack {
                        adjustmentsProfileView(profile)
                        Spacer()
                        if profile.expiresAt != nil, profile.previousProfileID != nil {
                            adjustmentsRevertProfileView()
                        }
                    }
                } else {
                    noActiveAdjustmentsView()
                }
            }.padding(.horizontal, 10)
                .confirmationDialog("Adjustment to Stop", isPresented: $showCancelConfirmDialog) {
                    Button("Stop Override", role: .destructive) {
                        Task {
                            guard let objectID = latestOverride.first?.objectID else { return }
                            await state.cancelOverride(withID: objectID)
                        }
                    }
                    Button("Stop Temp Target", role: .destructive) {
                        Task {
                            guard let objectID = latestTempTarget.first?.objectID else { return }
                            await state.cancelTempTarget(withID: objectID)
                        }
                    }
                    Button("Stop All Adjustments", role: .destructive) {
                        Task {
                            guard let overrideObjectID = latestOverride.first?.objectID else { return }
                            await state.cancelOverride(withID: overrideObjectID)

                            guard let tempTargetObjectID = latestTempTarget.first?.objectID else { return }
                            await state.cancelTempTarget(withID: tempTargetObjectID)
                        }
                    }
                } message: {
                    Text("Select Adjustment")
                }
        }
    }

    @ViewBuilder func bolusProgressBar(_ progress: Decimal) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 15)
                .frame(height: 6)
                .foregroundColor(.clear)
                .background(
                    TaiStyle.linearGradient(
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                    .mask(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 15)
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                )
        }
    }

    @ViewBuilder func bolusProgressView(_ progress: Decimal) -> some View {
        /// ensure that state.lastPumpBolus has a value, i.e. there is a last bolus done by the pump and not an external bolus
        /// - TRUE:  show the pump bolus
        /// - FALSE:  do not show a progress bar at all
        if let bolusTotal = state.lastPumpBolus?.bolus?.amount {
            let bolusFraction = progress * (bolusTotal as Decimal)
            let bolusString =
                (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view") +
                    (bolusProgressFormatter.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")

            ZStack {
                /// rectangle as background
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        colorScheme == .dark ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745) : Color
                            .insulin
                            .opacity(0.1)
                    )
                    .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.35 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .frame(height: HomeLayout.bottomPanelHeight)
                    .shadow(
                        color: (overrideString != nil || tempTargetString != nil) ?
                            (
                                colorScheme == .dark ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706) :
                                    Color.black.opacity(0.33)
                            ) : Color.clear,
                        radius: 3
                    )

                /// actual bolus view
                HStack {
                    Image("bolus")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 25, height: 25)
                        .foregroundColor(Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902))

                    Spacer()
                    Group {
                        Text("Bolusing")
                            .font(.subheadline)
                        Text(bolusString)
                            .font(.subheadline)
                    }.padding(.leading, 5)

                    Spacer()

                    Button {
                        state.showProgressView()
                        state.cancelBolus()
                    } label: {
                        Image(systemName: "xmark.app")
                            .font(.system(size: 25))
                            .foregroundStyle(Color.primary, Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902))
                    }
                }.padding(.horizontal, 10)
            }
            .overlay(alignment: .bottom) {
                let offset = HomeLayout.bottomPanelHeight * 0.75
                bolusProgressBar(progress)
                    .padding(.leading, 42)
                    .padding(.trailing, 50)
                    .offset(y: offset)
            }.clipShape(RoundedRectangle(cornerRadius: 15))
        }
    }
}
