import Foundation
import UserNotifications

/// Local notifications for new activity, the "stopped watching" watchdog, and routing a tap
/// to the right profile.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let watchdogID = "ninjaview.watchdog"

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

    func notify(handle: String, name: String, activity: Activity, count: Int, timeSensitive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "@\(handle)" : "\(name) (@\(handle))"
        content.body = Self.body(for: activity, count: count)
        content.sound = .default
        content.threadIdentifier = handle.lowercased()
        content.userInfo = ["handle": handle]
        // Takes effect only in the TrollStore build, which keeps the time-sensitive entitlement.
        if timeSensitive { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: "\(handle.lowercased())-\(activity.rawValue)-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Task { @MainActor in DebugLog.shared.add(.watch, "Notified about @\(handle): \(content.body)") }
    }

    static func body(for activity: Activity, count: Int) -> String {
        switch activity {
        case .video: return count == 1 ? "Shared a new post" : "Shared \(count) new posts"
        case .story: return count == 1 ? "Added a new story" : "Added \(count) new stories"
        case .repost: return count == 1 ? "Reposted a video" : "Reposted \(count) videos"
        }
    }

    /// Pushed further into the future on every Instant-mode check. If checks stop, it fires.
    func scheduleWatchdog(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "NinjaView stopped watching"
        content.body = "Instant mode hasn't checked in for a while, so new posts could be missed. Open NinjaView to start it again."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: watchdogID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func cancelWatchdog() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [watchdogID])
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
