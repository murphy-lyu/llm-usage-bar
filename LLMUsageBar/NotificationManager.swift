import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func notifyLimit(label: String, percent: Int, percentMode: Config.PercentDisplayMode, level: String) {
        let content = UNMutableNotificationContent()
        let titleKey = percentMode == .remaining ? "alert.title.remaining" : "alert.title.used"
        content.title = String(format: titleKey.l10n, percent)
        content.body = String(format: "alert.body".l10n, label)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "llm-usage-bar.\(level).\(label)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
