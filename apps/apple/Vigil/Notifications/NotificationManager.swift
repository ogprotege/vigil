import Foundation
import OSLog
import UserNotifications
import VigilKit

/// Turns ThresholdEngine crossings into local notifications. The engine is
/// pure; every side effect lives here.
final class NotificationManager: Sendable {
    private static let log = Logger(subsystem: "app.vigil", category: "notifications")
    private static var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    func requestAuthorizationIfNeeded() async {
        // UNUserNotificationCenter raises an Objective-C exception when used
        // from a headless XCTest or preview host without an application
        // bundle. There is no notification destination in that environment.
        guard Self.hasApplicationBundle else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.log.error(
                "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns events the operating system did not accept. Callers keep those
    /// events in durable storage and retry later.
    func deliver(events: [ThresholdEvent], account: AccountRef) async -> [ThresholdEvent] {
        guard Self.hasApplicationBundle else { return events }
        let center = UNUserNotificationCenter.current()
        var failed: [ThresholdEvent] = []
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
            do {
                try await center.add(request)
            } catch {
                failed.append(event)
                Self.log.error(
                    "Could not schedule threshold notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return failed
    }

    private func windowName(_ id: String) -> String {
        switch id {
        case "session": return "session"
        case "weekly": return "weekly"
        case "weekly_sonnet": return "Sonnet weekly"
        case "weekly_opus": return "Opus weekly"
        case "session_video": return "Video session"
        case "weekly_video": return "Video weekly"
        default: return id.replacingOccurrences(of: "_", with: " ")
        }
    }
}
