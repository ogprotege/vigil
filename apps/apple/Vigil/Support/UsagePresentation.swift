import Foundation
import VigilKit

struct LimitCandidate: Equatable {
    let account: AccountRef
    let snapshot: ProviderSnapshot
    let window: UsageWindow
}

struct WatchlineCoverage: Equatable {
    let linkedAccountCount: Int
    let windowAccountCount: Int
    let metricOnlyAccountCount: Int
    let unreliableAccountCount: Int

    var isComplete: Bool {
        unreliableAccountCount == 0
    }
}

/// One presentation policy shared by the dashboard, menu bar, and tests.
/// Provider data stays intact; this layer only gives each window an honest,
/// human-readable name and a consistent "percent left" representation.
enum UsagePresentation {
    static func remainingPercent(for window: UsageWindow) -> Double {
        min(max(100 - window.utilization, 0), 100)
    }

    static func title(for window: UsageWindow) -> String {
        switch window.id.lowercased() {
        case "session":
            return durationTitle(seconds: window.windowSeconds) ?? "Session limit"
        case "weekly":
            return "Weekly limit"
        case "monthly":
            return "Monthly limit"
        case "plan":
            return "Plan limit"
        case "billing":
            return "Billing limit"
        case "weekly_sonnet":
            return "Sonnet weekly"
        case "weekly_opus":
            return "Opus weekly"
        default:
            return humanizedIdentifier(window.id)
        }
    }

    static func compactTitle(for window: UsageWindow) -> String {
        title(for: window)
            .replacingOccurrences(of: " limit", with: "")
    }

    static func category(for window: UsageWindow) -> String {
        switch window.id.lowercased() {
        case "session": return "ROLLING WINDOW"
        case "weekly": return "WEEKLY WINDOW"
        case "monthly": return "MONTHLY WINDOW"
        case "plan": return "PLAN WINDOW"
        case "billing": return "BILLING WINDOW"
        default:
            if window.secondary {
                return window.id.lowercased().hasPrefix("weekly_")
                    ? "MODEL LIMIT"
                    : "SPECIAL LIMIT"
            }
            return "USAGE WINDOW"
        }
    }

    static func isSpecialWindow(_ window: UsageWindow) -> Bool {
        switch window.id.lowercased() {
        case "session", "weekly", "monthly", "plan", "billing":
            return false
        default:
            return window.secondary
        }
    }

    static func sortedWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted {
            let left = sortRank($0)
            let right = sortRank($1)
            if left != right { return left < right }
            return title(for: $0).localizedCaseInsensitiveCompare(title(for: $1)) == .orderedAscending
        }
    }

    static func closestLimit(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot]
    ) -> LimitCandidate? {
        accounts
            .compactMap { account -> [LimitCandidate]? in
                guard let snapshot = snapshots[account.key] else { return nil }
                return snapshot.windows.map {
                    LimitCandidate(account: account, snapshot: snapshot, window: $0)
                }
            }
            .flatMap { $0 }
            .min {
                let left = remainingPercent(for: $0.window)
                let right = remainingPercent(for: $1.window)
                if left != right { return left < right }
                return sortRank($0.window) < sortRank($1.window)
            }
    }

    static func watchlineCoverage(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot],
        at now: Date = Date()
    ) -> WatchlineCoverage {
        var windowAccounts = 0
        var metricOnlyAccounts = 0
        var unreliableAccounts = 0

        for account in accounts {
            guard let snapshot = snapshots[account.key] else {
                unreliableAccounts += 1
                continue
            }
            guard !SnapshotFreshness.isDegraded(
                status: snapshot.status,
                fetchedAt: snapshot.fetchedAt,
                at: now
            ) else {
                if !snapshot.windows.isEmpty {
                    windowAccounts += 1
                }
                unreliableAccounts += 1
                continue
            }
            if !snapshot.windows.isEmpty {
                windowAccounts += 1
            } else if !snapshot.metrics.isEmpty {
                metricOnlyAccounts += 1
            } else {
                unreliableAccounts += 1
            }
        }

        return WatchlineCoverage(
            linkedAccountCount: accounts.count,
            windowAccountCount: windowAccounts,
            metricOnlyAccountCount: metricOnlyAccounts,
            unreliableAccountCount: unreliableAccounts
        )
    }

    static func accountTitle(_ account: AccountRef) -> String {
        guard let label = account.label?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !label.isEmpty else {
            return account.displayName
        }
        return "\(account.displayName) · \(label)"
    }

    static func statusTitle(_ status: SnapshotStatus) -> String {
        switch status {
        case .ok: return "Live"
        case .rateLimited: return "Cooling down"
        case .authExpired: return "Re-link needed"
        case .schemaChanged: return "Provider changed"
        case .network: return "Offline"
        }
    }

    static func statusSymbol(_ status: SnapshotStatus) -> String? {
        switch status {
        case .ok: return nil
        case .rateLimited: return "hourglass"
        case .authExpired: return "key.slash"
        case .schemaChanged: return "exclamationmark.triangle"
        case .network: return "wifi.slash"
        }
    }

    private static func sortRank(_ window: UsageWindow) -> Int {
        switch window.id.lowercased() {
        case "session": return 0
        case "weekly": return 10
        case "monthly": return 20
        case "plan": return 30
        case "billing": return 40
        default: return window.secondary ? 100 : 50
        }
    }

    private static func durationTitle(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds == 3_600 { return "Hourly limit" }
        if seconds.isMultiple(of: 3_600) {
            let hours = seconds / 3_600
            if hours < 24 { return "\(hours)-hour limit" }
        }
        if seconds == 604_800 { return "Weekly limit" }
        if seconds.isMultiple(of: 86_400) {
            return "\(seconds / 86_400)-day limit"
        }
        return nil
    }

    private static func humanizedIdentifier(_ id: String) -> String {
        id
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(humanizedToken)
            .joined(separator: " ")
    }

    private static func humanizedToken(_ token: Substring) -> String {
        token
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { part in
                let lower = part.lowercased()
                if ["gpt", "api", "ai"].contains(lower) {
                    return lower.uppercased()
                }
                if lower == "codex" { return "Codex" }
                if lower == "sonnet" { return "Sonnet" }
                if lower == "opus" { return "Opus" }
                if lower.allSatisfy(\.isNumber) { return lower }
                return lower.prefix(1).uppercased() + String(lower.dropFirst())
            }
            .joined(separator: "-")
    }
}
