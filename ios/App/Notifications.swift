import Combine
import Foundation
import os
import UIKit
import UserNotifications

/// Permission for notifications, and the APNs device token. The low/high reminders (plan §1)
/// come from the relay as ordinary alert pushes to that token; the change reminders
/// (`ChangeReminderController`) are scheduled on the phone and need the permission only. Both
/// follow silent mode and Focus like any notification and do not replace the CGM app's alarms.
@MainActor
final class NotificationController: ObservableObject {
    static let shared = NotificationController()

    @Published private(set) var deviceToken: String?
    /// The user said no to notifications; the switch explains where to allow them.
    @Published private(set) var denied = false

    /// Called when the device token arrives or changes.
    var onDeviceToken: (() -> Void)?

    private let logger = Logger(subsystem: "ninja.jepsen.naensom", category: "notifications")

    /// Asks for permission and, when given and `remote` (the low/high reminders), registers for
    /// remote notifications. Answers whether notifications are allowed.
    func requestPermission(remote: Bool = true) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        denied = !granted
        if granted && remote { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    /// At launch, when a kind of reminder is on: sees whether notifications are still allowed and,
    /// for the low/high reminders (`remote`), registers again (the token can change), without asking.
    func registerIfAllowed(remote: Bool = true) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            denied = false
            if remote { UIApplication.shared.registerForRemoteNotifications() }
        case .denied:
            denied = true
        default:
            break
        }
    }

    func received(_ token: String) {
        logger.notice("device token received")
        guard token != deviceToken else { return }
        deviceToken = token
        onDeviceToken?()
    }

    func reset() {
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        denied = false
    }
}

/// Receives the APNs device token, shows a reminder that arrives while the app is open, and takes
/// a change reminder's snooze action.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ChangeReminderController.registerCategory()
        // Also runs when iOS launches the app in the background (the relay started a Live Activity
        // by push, say), where no window appears: the new activity's token is registered and the
        // one it replaces ended (`AppModel.wake`), and a removal the relay has not confirmed is
        // tried again then too.
        Task { @MainActor in
            AppModel.shared.wake()
            PendingUnregisterSync.shared.retryIfDue()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.hexString
        Task { @MainActor in NotificationController.shared.received(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: "ninja.jepsen.naensom", category: "notifications").error("remote notification registration failed")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A snooze action on a change reminder. iOS runs the app in the background for it, so the
    /// reminder is put off without the app opening. A tap on the notification itself opens the app
    /// and needs nothing here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let part = info["part"] as? String
        let lastAt = info["lastAt"] as? Double
        Task { @MainActor in
            await AppModel.shared.changeReminderAction(action, part: part, lastAt: lastAt)
            completionHandler()
        }
    }
}
