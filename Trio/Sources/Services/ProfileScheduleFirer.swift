import CoreData
import Foundation
import Swinject
import UserNotifications

/// App-lifetime service that fires due `ProfileScheduleStored` rows. Registered in
/// `ServiceAssembly` with container scope and resolved at startup so the sweep loop outlives any
/// view. This replaces an earlier attempt that ran the check inside `Home.StateModel`'s 5-second
/// timer — that only worked while Home was visible, so navigating into Settings halted firing.
///
/// The loop sleeps for `sweepInterval` between checks. A re-entrancy guard prevents overlap while
/// `provider.activate()` is in flight on the pump-sync path.
///
/// **Prototype scope:** only timed (`.hours`) schedules fire automatically. Indefinite and
/// `.untilNext` require user-confirmed pump save and are deferred to PR 5 (actionable local
/// notifications). Once-schedules auto-disable after firing.
final class ProfileScheduleFirer {
    private let resolver: Resolver
    private let coreDataStack = CoreDataStack.shared

    /// Time between sweeps. Testing: 5s. Production target: 15s. TODO: restore 15s before ship.
    private let sweepInterval: TimeInterval = 5

    private var loopTask: Task<Void, Never>?
    private var sweepInFlight = false

    init(resolver: Resolver) {
        self.resolver = resolver
        // debug(.coreData, "ProfileScheduleFirer init — starting sweep loop")
        startLoop()
    }

    deinit {
        loopTask?.cancel()
    }

    private func startLoop() {
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await sweep()
                try? await Task.sleep(nanoseconds: UInt64(sweepInterval * 1_000_000_000))
            }
        }
    }

    private func sweep() async {
        guard !sweepInFlight else {
            // debug(.coreData, "ProfileScheduleFirer: sweep skipped (in flight)")
            return
        }
        sweepInFlight = true
        defer { sweepInFlight = false }

        let context = coreDataStack.newTaskContext()
        let now = Date()
        // debug(.coreData, "ProfileScheduleFirer: sweep tick @ \(now)")

        let due: [DueFire] = await context.perform {
            // Pre-resolve profile names so indefinite-fire notifications can reference the
            // target profile by name rather than a bare UUID.
            let profiles = (try? context.fetch(ProfileStored.fetchRequest())) ?? []
            let nameByID: [UUID: String] = profiles.reduce(into: [:]) { dict, p in
                if let id = p.id { dict[id] = p.name ?? "" }
            }

            let request = ProfileScheduleStored.fetch(.enabledSchedule)
            let rows = (try? context.fetch(request)) ?? []
            // debug(.coreData, "ProfileScheduleFirer: \(rows.count) enabled schedules in store")
            return rows.compactMap { row -> DueFire? in
                guard let sid = row.id,
                      let pid = row.profileID,
                      let rule = row.rule,
                      let duration = row.duration
                else {
                    // debug(.coreData, "ProfileScheduleFirer: row decode failed (id/profile/rule/duration)")
                    return nil
                }
                let anchor = row.lastFiredAt ?? row.createdAt ?? .distantPast
                let nextMaybe = rule.nextFire(after: anchor)
                debug(
                    .coreData,
                    "ProfileScheduleFirer: schedule \(sid) anchor=\(anchor) next=\(String(describing: nextMaybe)) now=\(now)"
                )
                guard let next = nextMaybe, next <= now else { return nil }
                let isOnce: Bool = {
                    if case .once = rule.repeatRule { return true }
                    return false
                }()
                return DueFire(
                    scheduleID: sid,
                    profileID: pid,
                    profileName: nameByID[pid] ?? "",
                    occurrence: next,
                    duration: duration,
                    isOnce: isOnce,
                    pendingOccurrence: row.pendingOccurrence,
                    objectID: row.objectID
                )
            }
            .sorted { $0.occurrence < $1.occurrence }
        }

        guard !due.isEmpty else { return }
        debug(.coreData, "ProfileScheduleFirer: \(due.count) due — firing")

        let provider = AdaptProfile.Provider(resolver: resolver)

        for fire in due {
            switch fire.duration {
            case let .minutes(m):
                // debug(.coreData, "ProfileScheduleFirer: activating \(fire.profileID) for \(m) min")
                let outcome = await provider.activate(
                    id: fire.profileID,
                    durationMinutes: m,
                    confirmedPumpSync: true
                )
                // debug(.coreData, "ProfileScheduleFirer: activate outcome = \(outcome)")
                if outcome != .success { continue }
                postActivatedNotification(for: fire, minutes: m)
            case .indefinite,
                 .untilNext:
                // Flow B: indefinite activations need user-confirmed pump save. Post an actionable
                // notification the first time we see this occurrence; skip re-posting on subsequent
                // sweeps until the user confirms, skips, or a new occurrence comes due.
                if fire.pendingOccurrence == fire.occurrence {
                    debug(
                        .coreData,
                        "ProfileScheduleFirer: \(fire.scheduleID) indefinite already pending user action"
                    )
                    continue
                }
                postActivationNotification(for: fire)
                await context.perform {
                    guard let row = try? context.existingObject(with: fire.objectID)
                        as? ProfileScheduleStored else { return }
                    row.pendingOccurrence = fire.occurrence
                    try? context.save()
                }
                continue
            }

            await context.perform {
                guard let row = try? context.existingObject(with: fire.objectID) as? ProfileScheduleStored
                else { return }
                if fire.isOnce {
                    // Once-schedules are not editable; deleting after fire is cleaner than
                    // leaving a disabled row cluttering the list.
                    context.delete(row)
                    // debug(.coreData, "ProfileScheduleFirer: deleted one-off \(fire.scheduleID) after fire")
                } else {
                    row.lastFiredAt = fire.occurrence
                    row.pendingOccurrence = nil
                    // debug(.coreData, "ProfileScheduleFirer: stamped lastFiredAt=\(fire.occurrence) on \(fire.scheduleID)")
                }
                try? context.save()
            }
        }

        // Wake anyone watching the schedule list (Profiles root Upcoming section + Schedules
        // management screen) so deleted / stamped rows disappear immediately instead of lingering
        // until the next manual refresh.
        await MainActor.run {
            Foundation.NotificationCenter.default.post(name: .didUpdateProfileSchedules, object: nil)
        }
    }

    // MARK: - Temp-profile activation notification (informational)

    private func postActivatedNotification(for fire: DueFire, minutes: Int) {
        let revertDate = fire.occurrence.addingTimeInterval(TimeInterval(minutes) * 60)
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let revertTime = timeFormatter.string(from: revertDate)

        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "Profile \"\(fire.profileName)\" activated",
            comment: "Title of schedule-fire notification (timed Flow A) — interpolated value is the profile name"
        )
        content.body = String(
            localized: "Temporary — active for \(formatDuration(minutes: minutes)), auto-reverts at \(revertTime).",
            comment: "Body of schedule-fire notification for a timed activation — first interpolated value is a duration like '3 hr 15 min', second is a clock time"
        )
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryIdentifier.scheduleActivated.rawValue
        content.userInfo = [
            ScheduleNotificationUserInfoKey.scheduleID: fire.scheduleID.uuidString,
            ScheduleNotificationUserInfoKey.profileID: fire.profileID.uuidString,
            ScheduleNotificationUserInfoKey.occurrenceEpoch: fire.occurrence.timeIntervalSince1970
        ]
        let request = UNNotificationRequest(
            identifier: "Trio.schedule.activated.\(fire.scheduleID.uuidString).\(Int(fire.occurrence.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debug(.service, "ProfileScheduleFirer: failed to post activated notification: \(error)")
            } else {
                debug(.service, "ProfileScheduleFirer: activated notification queued (id=\(request.identifier))")
            }
        }
    }

    private func formatDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours ==
            0
        {
            return String(
                localized: "\(mins) min",
                comment: "Temp-activation notification body fragment — duration in minutes only"
            ) }
        if mins ==
            0
        {
            return String(
                localized: "\(hours) hr",
                comment: "Temp-activation notification body fragment — duration in whole hours"
            ) }
        return String(
            localized: "\(hours) hr \(mins) min",
            comment: "Temp-activation notification body fragment — duration in hours and minutes"
        )
    }

    // MARK: - Flow B (indefinite) notification

    private func postActivationNotification(for fire: DueFire) {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "Save basal of Profile \"\(fire.profileName)\" to pump?",
            comment: "Title of schedule-fire notification for an indefinite activation that needs pump sync — interpolated value is the profile name"
        )
        content.body = String(
            localized: "An indefinite activation updates the pump's scheduled basal to match this profile. The pump's basal schedule will be overwritten.",
            comment: "Body of schedule-fire notification warning the user that confirming will overwrite the pump's basal schedule"
        )
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryIdentifier.scheduleActivation.rawValue
        content.userInfo = [
            ScheduleNotificationUserInfoKey.scheduleID: fire.scheduleID.uuidString,
            ScheduleNotificationUserInfoKey.profileID: fire.profileID.uuidString,
            ScheduleNotificationUserInfoKey.occurrenceEpoch: fire.occurrence.timeIntervalSince1970
        ]
        let request = UNNotificationRequest(
            identifier: "Trio.schedule.\(fire.scheduleID.uuidString).\(Int(fire.occurrence.timeIntervalSince1970))",
            content: content,
            trigger: nil // fire immediately
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            debug(
                .service,
                "ProfileScheduleFirer: posting notification — authStatus=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue)"
            )
            center.add(request) { error in
                if let error = error {
                    debug(
                        .service,
                        "ProfileScheduleFirer: failed to post activation notification: \(error)"
                    )
                } else {
                    debug(
                        .service,
                        "ProfileScheduleFirer: activation notification queued (id=\(request.identifier))"
                    )
                }
            }
        }
    }

    private struct DueFire {
        let scheduleID: UUID
        let profileID: UUID
        let profileName: String
        let occurrence: Date
        let duration: ProfileSchedule.Duration
        let isOnce: Bool
        let pendingOccurrence: Date?
        let objectID: NSManagedObjectID
    }
}
