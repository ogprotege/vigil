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
        let id = window.id.lowercased()
        switch id {
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
        case "weekly_oauth_apps":
            return "OAuth apps weekly"
        case "weekly_cowork":
            return "Cowork weekly"
        case "session_video":
            return "Video session"
        case "weekly_video":
            return "Video weekly"
        default:
            // Model-scoped windows (Claude limits[]) carry the model name as a
            // label; render "<Model> weekly" to match the Sonnet/Opus style.
            if id.hasPrefix("weekly_scoped"), let label = window.label {
                return "\(label) weekly"
            }
            return window.label ?? humanizedIdentifier(window.id)
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
                let id = window.id.lowercased()
                // A model name (label), a weekly_* id, or a per-model video lane
                // all read as a model-scoped quota rather than a special one.
                let isModelScoped = window.label != nil
                    || id.hasPrefix("weekly_")
                    || id.hasSuffix("_video")
                return isModelScoped ? "MODEL LIMIT" : "SPECIAL LIMIT"
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

    /// Every per-model / special limit across all accounts, tightest first —
    /// the data behind the dedicated Models view. When an account reports no
    /// special windows but does report primary session/weekly plan windows
    /// (Kimi K3, Z.ai coding plans, …), those primary windows are included so
    /// the Models tab is not empty for a successfully linked coding plan.
    static func modelLimits(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot]
    ) -> [LimitCandidate] {
        accounts
            .compactMap { account -> [LimitCandidate]? in
                guard let snapshot = snapshots[account.key] else { return nil }
                // ONLY genuine per-model / special windows. This used to fall
                // back to an account's primary session/weekly windows so the
                // tab was never empty for a coding plan — but that put Home's
                // data on Models under a "Per-model caps" heading, so a Codex
                // account with no model lanes rendered "Weekly limit" here as
                // if it were a model. An honest empty state beats a wrong row;
                // ModelsView already explains when a provider has no per-model
                // caps.
                let special = snapshot.windows.filter(isSpecialWindow)
                guard !special.isEmpty else { return nil }
                return special.map {
                    LimitCandidate(account: account, snapshot: snapshot, window: $0)
                }
            }
            .flatMap { $0 }
            .sorted {
                let left = remainingPercent(for: $0.window)
                let right = remainingPercent(for: $1.window)
                if left != right { return left < right }
                return title(for: $0.window)
                    .localizedCaseInsensitiveCompare(title(for: $1.window)) == .orderedAscending
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
                // Degraded accounts only count as unreliable — do not also
                // inflate windowAccountCount or the coverage copy contradicts
                // itself ("2 of 2 reporting" + "2 of 2 stale").
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

    /// One phrase for "this number is not current", used wherever a preserved
    /// last-good value is shown. A non-ok status names the reason; an ok-but-old
    /// snapshot reports its age. Never returns something that reads as live.
    static func stalenessNote(
        status: SnapshotStatus,
        fetchedAt: Date,
        at now: Date = Date()
    ) -> String {
        guard status == .ok else { return statusTitle(status) }
        guard fetchedAt > .distantPast else { return "No update yet" }
        let elapsed = max(0, now.timeIntervalSince(fetchedAt))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = elapsed >= 86_400 ? [.day] : (elapsed >= 3_600 ? [.hour] : [.minute])
        let age = formatter.string(from: elapsed) ?? "a while"
        return "Updated \(age) ago"
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
