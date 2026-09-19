import Foundation
import UserNotifications

/// Posts through UNUserNotificationCenter. The center only works from a bundled app (it
/// throws for a bare executable such as `swift run`), so outside one it is never touched
/// and every post is dropped.
final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    /// Asks the first time only; macOS remembers the answer and drops posts after a no.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notification: QuotaNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    /// Banners show even while the app is frontmost, which it is whenever the popover is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .sound])
    }
}
