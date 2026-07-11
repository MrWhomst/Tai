import Foundation
import Observation
import SwiftUI

extension AdaptProfile {
    /// In-memory draft handed from `AddProfileForm` → `DraftEditorRootView`. Holds the source
    /// profile's values plus the percent-adjusted therapy values, ready for further editing.
    struct NewProfileDraft {
        var name: String = ""
        /// Single therapy percentage. Higher = more aggressive (more insulin): basal scales up,
        /// ISF and CR scale down proportionally.
        var adjustPercent: Decimal = 100

        var preferencesSource = Preferences()

        var originalBasal: [BasalProfileEntry] = []
        /// Basal rates after `% / 100` scaling and pump-supported rounding.
        var finalBasal: [BasalProfileEntry] = []

        var originalSensitivities: InsulinSensitivities = .init(
            units: .mgdL, userPreferredUnits: .mgdL, sensitivities: []
        )
        var adjustedSensitivities: InsulinSensitivities = .init(
            units: .mgdL, userPreferredUnits: .mgdL, sensitivities: []
        )

        var originalCarbRatios: CarbRatios = .init(units: .grams, schedule: [])
        var adjustedCarbRatios: CarbRatios = .init(units: .grams, schedule: [])

        var bgTargets: BGTargets = .init(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
    }

    @Observable final class StateModel: BaseStateModel<Provider> {
        var items: [AdaptProfileListItem] = []
        var upcoming: [UpcomingScheduleItem] = []
        var isLoading: Bool = false
        /// Populated when the user taps the body of a schedule-activation notification (default
        /// action, not the explicit Save-to-pump / Skip action buttons). Drives the in-app
        /// confirmation alert on RootView.
        var pendingScheduledActivation: ScheduledActivationRequest?

        var draft = NewProfileDraft()

        override func subscribe() {
            Task { await refresh() }
            Foundation.NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSchedulesUpdated),
                name: .didUpdateProfileSchedules,
                object: nil
            )
            // Cover the race where the Foundation notification fires before we registered: refresh()
            // drains the mailbox, so the live-observer path is only needed when the StateModel is
            // already alive and the tap arrives mid-session.
            Foundation.NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScheduleNotificationTap(_:)),
                name: .didTapScheduleNotification,
                object: nil
            )
        }

        @objc private func handleSchedulesUpdated() {
            Task { @MainActor in await refresh() }
        }

        @objc private func handleScheduleNotificationTap(_ note: Notification) {
            guard let info = note.userInfo,
                  let scheduleID = info[ScheduleNotificationUserInfoKey.scheduleID] as? UUID,
                  let profileID = info[ScheduleNotificationUserInfoKey.profileID] as? UUID,
                  let occurrenceEpoch = info[ScheduleNotificationUserInfoKey.occurrenceEpoch] as? Double
            else { return }
            let occurrence = Date(timeIntervalSince1970: occurrenceEpoch)
            Task { @MainActor in
                if items.isEmpty { await refresh() }
                let name = items.first(where: { $0.id == profileID })?.name ?? "Scheduled profile"
                pendingScheduledActivation = ScheduledActivationRequest(
                    scheduleID: scheduleID,
                    profileID: profileID,
                    profileName: name,
                    occurrence: occurrence
                )
            }
        }

        /// Alert "Save to pump" button — activates indefinitely with pump sync and stamps the
        /// schedule so the firer moves on. Takes the request by value (captured at alert creation)
        /// so SwiftUI's auto-dismiss setting `pendingScheduledActivation = nil` doesn't wipe state
        /// before the Task runs.
        @MainActor func confirmScheduledActivation(request req: ScheduledActivationRequest) async {
            pendingScheduledActivation = nil
            await provider.markScheduleActivated(scheduleID: req.scheduleID, occurrence: req.occurrence)
            _ = await provider.activate(
                id: req.profileID,
                durationMinutes: nil,
                confirmedPumpSync: true
            )
            await refresh()
            Foundation.NotificationCenter.default.post(
                name: .didUpdateProfileSchedules,
                object: nil
            )
        }

        /// Alert "Skip" button — stamps the schedule as handled without activating.
        @MainActor func skipScheduledActivation(request req: ScheduledActivationRequest) async {
            pendingScheduledActivation = nil
            await provider.markScheduleActivated(scheduleID: req.scheduleID, occurrence: req.occurrence)
            Foundation.NotificationCenter.default.post(
                name: .didUpdateProfileSchedules,
                object: nil
            )
        }

        @MainActor func refresh() async {
            isLoading = true
            async let itemsTask = provider.fetchAll()
            async let upcomingTask = provider.fetchUpcoming()
            async let pendingTask = provider.earliestPendingScheduledActivation()
            items = await itemsTask
            upcoming = await upcomingTask
            let reconciled = await pendingTask
            isLoading = false
            drainPendingTap()
            // Auto-surface: if no tap-driven request is already showing and a schedule still has
            // a pendingOccurrence outstanding (user dismissed the notification without acting),
            // present the Save-to-pump dialog as soon as they land on AdaptProfile.
            if pendingScheduledActivation == nil { pendingScheduledActivation = reconciled }
        }

        /// Pulls any pending schedule-notification tap from the process mailbox and converts it
        /// into a `ScheduledActivationRequest` with the target profile's current name. One-shot.
        @MainActor private func drainPendingTap() {
            guard pendingScheduledActivation == nil,
                  let tap = ScheduledActivationMailbox.drain()
            else { return }
            let name = items.first(where: { $0.id == tap.profileID })?.name ?? "Scheduled profile"
            pendingScheduledActivation = ScheduledActivationRequest(
                scheduleID: tap.scheduleID,
                profileID: tap.profileID,
                profileName: name,
                occurrence: tap.occurrence
            )
        }

        func disableSchedule(_ item: UpcomingScheduleItem) {
            Task {
                await provider.disableSchedule(id: item.id)
                await refresh()
            }
        }

        func rename(_ item: AdaptProfileListItem, to newName: String) {
            Task {
                await provider.rename(id: item.id, to: newName)
                await refresh()
            }
        }

        func delete(_ item: AdaptProfileListItem) {
            Task {
                await provider.delete(id: item.id)
                await refresh()
            }
        }

        @MainActor func activate(
            id: UUID,
            durationMinutes: Int?,
            confirmedPumpSync: Bool,
            skipPumpSync: Bool = false
        ) async -> ActivationOutcome {
            let outcome = await provider.activate(
                id: id,
                durationMinutes: durationMinutes,
                confirmedPumpSync: confirmedPumpSync,
                skipPumpSync: skipPumpSync
            )
            if outcome == .success {
                await refresh()
            }
            return outcome
        }

        @MainActor func reorder(from source: IndexSet, to destination: Int) {
            items.move(fromOffsets: source, toOffset: destination)
            let ids = items.map(\.id)
            Task {
                await provider.applyOrdering(ids)
                await refresh()
            }
        }

        /// Reorder the inactive subset of `items` while keeping the active profile pinned at the
        /// top. The active profile is rendered in its own section so it shouldn't participate in
        /// the draggable list.
        @MainActor func reorderInactive(from source: IndexSet, to destination: Int) {
            let active = items.filter(\.isActive)
            var inactive = items.filter { !$0.isActive }
            inactive.move(fromOffsets: source, toOffset: destination)
            items = active + inactive
            let ids = items.map(\.id)
            Task {
                await provider.applyOrdering(ids)
                await refresh()
            }
        }

        /// Resets the draft to reflect current live settings with neutral (100%) percentages.
        func startNewDraft() {
            var d = NewProfileDraft()
            d.preferencesSource = scope.preferences
            d.originalBasal = scope.basalProfile
            d.originalSensitivities = scope.sensitivities
            d.adjustedSensitivities = scope.sensitivities
            d.originalCarbRatios = scope.carbRatios
            d.adjustedCarbRatios = scope.carbRatios
            d.bgTargets = scope.bgTargets
            draft = d
        }

        /// Applies the draft's current percentage to the source therapy values: basal is scaled
        /// and rounded down to a pump-supported rate, ISF/CR are scaled and quantized to the
        /// picker step sizes. Targets are not percentage-adjusted.
        func applyPercentagesToDraft() {
            let concentration = settingsManager.settings.insulinConcentration
            let supportedRaw = provider.supportedBasalRates ?? Self.fallbackBasalRates(pumpIncrement: 0.05)
            let supported = supportedRaw.map { $0 * concentration }.sorted()

            let basalFactor = draft.adjustPercent / 100
            let isfFactor = 100 / draft.adjustPercent
            let crFactor = 100 / draft.adjustPercent

            // Basal — apply percentage, then round down to nearest pump-supported rate
            draft.finalBasal = draft.originalBasal.map { entry in
                let adjusted = entry.rate * basalFactor
                let rounded = supported.last(where: { $0 <= adjusted }) ?? (supported.first ?? adjusted)
                return BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rounded)
            }

            // ISF — scale each sensitivity, then quantize to the ISF picker step (1 mg/dL)
            let scaledSensitivities = draft.originalSensitivities.sensitivities.map { entry in
                InsulinSensitivityEntry(
                    sensitivity: Self.roundToStep(entry.sensitivity * isfFactor, step: 1),
                    offset: entry.offset,
                    start: entry.start
                )
            }
            draft.adjustedSensitivities = InsulinSensitivities(
                units: draft.originalSensitivities.units,
                userPreferredUnits: draft.originalSensitivities.userPreferredUnits,
                sensitivities: scaledSensitivities
            )

            // CR — scale each ratio, then quantize to the CR picker step (0.1 g/U)
            let scaledRatios = draft.originalCarbRatios.schedule.map { entry in
                CarbRatioEntry(
                    start: entry.start,
                    offset: entry.offset,
                    ratio: Self.roundToStep(entry.ratio * crFactor, step: 0.1)
                )
            }
            draft.adjustedCarbRatios = CarbRatios(
                units: draft.originalCarbRatios.units,
                schedule: scaledRatios
            )
        }

        /// Round `value` to the nearest multiple of `step` (plain rounding, half-up).
        private static func roundToStep(_ value: Decimal, step: Decimal) -> Decimal {
            guard step > 0 else { return value }
            var divided = value / step
            var rounded = Decimal()
            NSDecimalRound(&rounded, &divided, 0, .plain)
            return rounded * step
        }

        private static func fallbackBasalRates(pumpIncrement: Decimal) -> [Decimal] {
            // 0.05 → 30 U/hr, same ceiling BasalProfileEditor uses
            var out: [Decimal] = []
            var current: Decimal = pumpIncrement
            while current <= 30 {
                out.append(current)
                current += pumpIncrement
            }
            return out
        }
    }
}
