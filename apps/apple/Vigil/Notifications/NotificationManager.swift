import Foundation
import UserNotifications
import VigilKit

/// Turns ThresholdEngine crossings into local notifications. The engine is
/// pure; every side effect lives here.
final class NotificationManager: Sendable {
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(events: [ThresholdEvent], account: AccountRef) async {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "\(account.displayName) \(windowName(event.windowId)) at \(Int(event.utilization.rounded()))%"
            content.body = event.threshold >= 95
                ? "You're nearly out — heavy work will hit the limit soon."
                : "Crossed \(event.threshold)% of the \(windowName(event.windowId)) window."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "app.vigil.threshold.\(account.key).\(event.windowId).\(event.threshold)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func windowName(_ id: String) -> String {
        switch id {
        case "session": return "session"
        case "weekly": return "weekly"
        case "weekly_sonnet": return "Sonnet weekly"
        case "weekly_opus": return "Opus weekly"
        default: return id.replacingOccurrences(of: "_", with: " ")
        }
    }
}
