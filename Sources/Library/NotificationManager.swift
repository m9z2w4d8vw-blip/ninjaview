import Foundation
import UserNotifications

/// Local notifications for new posts, and routing a tap to the right profile.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once; returns whether notifications are allowed now.
    func requestAuthorization() async -> Bool {
        let notifications = UNUserNotificationCenter.current()
        let settings = await notifications.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            await MainActor.run { DebugLog.shared.warn(.watch, "Notifications are turned off for NinjaView in iOS Settings") }
            return false
        default:
            do {
                return try await notifications.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                await MainActor.run { DebugLog.shared.warn(.watch, "Notification permission request failed: \(error.localizedDescription)") }
                return false
            }
        }
    }

    func notifyNewPosts(handle: String, name: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "@\(handle)" : "\(name) (@\(handle))"
        content.body = count == 1 ? "Posted a new video" : "Posted \(count) new videos"
        content.sound = .default
        content.threadIdentifier = handle.lowercased()
        content.userInfo = ["handle": handle]
        let request = UNNotificationRequest(identifier: "\(handle.lowercased())-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Task { @MainActor in DebugLog.shared.add(.watch, "Notified about @\(handle): \(count) new") }
    }

    // Show the banner even while NinjaView is open.
    func userNotificationCenter(_ notifications: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tapping a notification opens that profile.
    func userNotificationCenter(_ notifications: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let handle = response.notification.request.content.userInfo["handle"] as? String else { return }
        await MainActor.run { _ = AppModel.shared.open("@" + handle) }
    }
}
