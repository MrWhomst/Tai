import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Default to `true` if the key doesn't exist — Trio is opt-out, not opt-in.
        // Read before touching Firebase: an explicit opt-out means we never
        // configure it, so no component can queue or upload anything.
        let crashReportingEnabled: Bool = PropertyPersistentFlags.shared.crashlyticsSharingEnabled ?? true
        CrashReportingGate.configureAtLaunch(enabled: crashReportingEnabled)

        // Telemetry: record this cold launch into the sliding 7-day window. If
        // consent is set and the build SHA changed since the last successful
        // send, fire an immediate ping — the 24h scheduler can't notice a
        // build update on its own. Then arm the recurring 24h timer.
        TelemetryClient.shared.recordColdLaunch()
        Task.detached {
            if TelemetryClient.shared.buildShaChangedSinceLastSend() {
                await TelemetryClient.shared.maybeSend()
            }
            TelemetryClient.shared.scheduleRecurring()
        }

        return true
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        debug(.remoteControl, "Received notification")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
            let encryptedMessage = try JSONDecoder().decode(EncryptedPushMessage.self, from: jsonData)

            Task {
                do {
                    try await TrioRemoteControl.shared.handleRemoteNotification(encryptedData: encryptedMessage.encryptedData)
                    completionHandler(.newData)
                } catch {
                    debug(
                        .default,
                        "\(DebuggingIdentifiers.failed) failed to handle remote notification with error: \(error)"
                    )
                    completionHandler(.failed)
                }
            }
        } catch {
            debug(.remoteControl, "Error decoding push message shell: \(error)")
            completionHandler(.failed)
        }
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()

        Task {
            do {
                try await TrioRemoteControl.shared.handleAPNSChanges(deviceToken: token)
            } catch {
                debug(
                    .remoteControl,
                    "\(DebuggingIdentifiers.failed) failed to register for remote notifications: \(error)"
                )
            }
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        debug(.remoteControl, "Failed to register for remote notifications: \(error)")
    }
}
