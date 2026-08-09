import CryptoKit
import Foundation
import OSLog
import UserNotifications
import VigilKit

/// Turns ThresholdEngine crossings into local notifications. The engine is
/// pure; every side effect lives here.
protocol NotificationManaging: Sendable {
    func requestAuthorizationIfNeeded() async
    func removeLegacyNotifications() async
    func removeAllVigilNotifications() async
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent]
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String,
        hidesDetails: Bool
    ) async -> [ThresholdEvent]
    func removeNotifications(accountKey: String) async
    func removeNotifications(identifiers: [String]) async
}

extension NotificationManaging {
    /// Test doubles and embedders without a system notification center need no
    /// migration work. NotificationManager supplies the production cleanup.
    func removeLegacyNotifications() async {}
    func removeAllVigilNotifications() async {}

    /// Existing test doubles can continue recording delivery without knowing
    /// how production notification copy is rendered.
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String,
        hidesDetails: Bool
    ) async -> [ThresholdEvent] {
        await deliver(
            events: events,
            account: account,
            deliveryScope: deliveryScope
        )
    }
}

final class NotificationManager: NotificationManaging, Sendable {
    private static let log = Logger(subsystem: "app.vigil", category: "notifications")
    private static var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
    static var canUseSystemNotifications: Bool {
        let environment = ProcessInfo.processInfo.environment
        let isTesting = environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let isPreview = environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        return hasApplicationBundle && !isTesting && !isPreview
    }

    func requestAuthorizationIfNeeded() async {
        // App-hosted iOS tests have an .app bundle, but asking the system
        // center for authorization can present UI and suspend the test run.
        // Tests and previews have no notification destination.
        guard Self.canUseSystemNotifications else { return }
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

    /// Builds through 0.14 wrote raw account keys into notification IDs. An
    /// account removed by that build may have no remaining index or Keychain
    /// record from which to reconstruct its key, so migrate by shape once the
    /// app can inspect Notification Center. Current IDs are exactly two
    /// SHA-256 components and are preserved.
    func removeLegacyNotifications() async {
        guard Self.canUseSystemNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: Self.legacyNotificationIdentifiers(
                among: pending.map(\.identifier)
            )
        )
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(
            withIdentifiers: Self.legacyNotificationIdentifiers(
                among: delivered.map { $0.request.identifier }
            )
        )
    }

    /// Removes only Vigil-owned threshold notifications. Used by the explicit
    /// full local-data recovery when damaged identity stores cannot enumerate
    /// notifications account by account.
    func removeAllVigilNotifications() async {
        guard Self.canUseSystemNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: Self.allVigilNotificationIdentifiers(
                among: pending.map(\.identifier)
            )
        )
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(
            withIdentifiers: Self.allVigilNotificationIdentifiers(
                among: delivered.map { $0.request.identifier }
            )
        )
    }

    /// Returns events the operating system did not accept. Callers keep those
    /// events in durable storage and retry later.
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] {
        await deliver(
            events: events,
            account: account,
            deliveryScope: deliveryScope,
            hidesDetails: false
        )
    }

    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String,
        hidesDetails: Bool
    ) async -> [ThresholdEvent] {
        guard Self.canUseSystemNotifications else { return events }
        let center = UNUserNotificationCenter.current()
        var failed: [ThresholdEvent] = []
        for event in events {
            let content = UNMutableNotificationContent()
            let copy = Self.notificationCopy(
                event: event,
                account: account,
                hidesDetails: hidesDetails
            )
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(
                    accountKey: account.key,
                    deliveryScope: deliveryScope,
                    event: event
                ),
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

    struct Copy: Equatable {
        let title: String
        let body: String
    }

    static func notificationCopy(
        event: ThresholdEvent,
        account: AccountRef,
        hidesDetails: Bool
    ) -> Copy {
        guard !hidesDetails else {
            return Copy(
                title: "Vigil usage alert",
                body: "Open Vigil to view the latest limit for a linked account."
            )
        }
        let window = windowName(event.windowId)
        return Copy(
            title: "\(account.displayName) \(window) at \(Int(event.utilization.rounded()))%",
            body: event.threshold >= 95
                ? "You're nearly out — heavy work will hit the limit soon."
                : "Crossed \(event.threshold)% of the \(window) window."
        )
    }

    /// Removes every queued or already-presented threshold notification for
    /// one account without exposing its account key to the system identifier.
    func removeNotifications(accountKey: String) async {
        guard Self.canUseSystemNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: Self.notificationIdentifiers(
                forAccountKey: accountKey,
                among: pending.map(\.identifier)
            )
        )
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(
            withIdentifiers: Self.notificationIdentifiers(
                forAccountKey: accountKey,
                among: delivered.map { $0.request.identifier }
            )
        )
    }

    /// Exact cleanup for an async delivery that became stale. Account-wide
    /// cleanup is intentionally reserved for the tombstoned removal flow,
    /// because the same account key may already belong to a new lifecycle.
    func removeNotifications(identifiers: [String]) async {
        guard Self.canUseSystemNotifications, !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func notificationIdentifier(
        accountKey: String,
        deliveryScope: String,
        event: ThresholdEvent
    ) -> String {
        let identity = [
            deliveryScope,
            event.windowId,
            String(event.threshold),
            event.resetSegment.map(String.init) ?? "no-reset",
        ].joined(separator: "\u{1F}")
        return "\(accountNotificationPrefix(accountKey: accountKey))\(digest(identity))"
    }

    static func accountNotificationPrefix(accountKey: String) -> String {
        "app.vigil.threshold.\(digest(accountKey))."
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func notificationIdentifiers(
        forAccountKey accountKey: String,
        among identifiers: [String]
    ) -> [String] {
        let prefix = accountNotificationPrefix(accountKey: accountKey)
        // Builds through 0.14 embedded the raw account key in notification
        // identifiers. Include that exact legacy namespace during removal so
        // an upgrade cannot leave private identifiers in Notification Center.
        // New notifications use only the non-reversible prefix above.
        let legacyPrefix = "app.vigil.threshold.\(accountKey)."
        return identifiers.filter {
            $0.hasPrefix(prefix) || $0.hasPrefix(legacyPrefix)
        }
    }

    static func legacyNotificationIdentifiers(among identifiers: [String]) -> [String] {
        let namespace = "app.vigil.threshold."
        return identifiers.filter { identifier in
            guard identifier.hasPrefix(namespace) else { return false }
            let suffix = identifier.dropFirst(namespace.count)
            let components = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2 else { return true }
            return !components.allSatisfy(isSHA256Hex)
        }
    }

    static func allVigilNotificationIdentifiers(among identifiers: [String]) -> [String] {
        identifiers.filter { $0.hasPrefix("app.vigil.threshold.") }
    }

    private static func isSHA256Hex(_ value: Substring) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }

    private static func windowName(_ id: String) -> String {
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
