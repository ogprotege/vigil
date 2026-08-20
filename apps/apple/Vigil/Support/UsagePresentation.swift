import Foundation
import VigilKit

/// One presentation policy shared by the dashboard, widgets, and tests.
/// Provider data stays intact; this layer only gives each window an honest,
/// human-readable name and a consistent "percent left" representation.
enum UsagePresentation {
    static func remainingPercent(for window: UsageWindow) -> Double {
        min(max(100 - window.utilization, 0), 100)
    }

    /// Some experimental providers expose percentage and amount fields that
    /// describe different allowance bases. Preserve both, but combine them as
    /// one denominator only when their ratio agrees within rounding tolerance.
    static func exactAmountsMatchUtilization(_ window: UsageWindow) -> Bool {
        guard let used = window.used, let limit = window.limit, limit > 0 else {
            return false
        }
        return abs((used / limit * 100) - window.utilization) <= 1
    }

    /// Spoken surface for the circular widget's fallback ring (no confirmed
    /// window, no metric to show). Mirrors SmallUsageView's visible copy so
    /// both families describe the state with the same words, in the
    /// "<display name>, <state>" shape of the circular family's siblings.
    static func circularFallbackAccessibilityLabel(accountDisplayName: String?) -> String {
        guard let accountDisplayName else { return "Vigil, no account linked" }
        return "\(accountDisplayName), waiting for first fetch"
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

    static func category(
        for window: UsageWindow,
        providerId: String? = nil
    ) -> String {
        switch window.id.lowercased() {
        case "session": return "ROLLING WINDOW"
        case "weekly": return "WEEKLY WINDOW"
        case "monthly": return "MONTHLY WINDOW"
        case "plan": return "PLAN WINDOW"
        case "billing": return "BILLING WINDOW"
        default:
            if window.secondary {
                return isModelWindow(window, providerId: providerId)
                    ? "MODEL LIMIT"
                    : "SPECIAL LIMIT"
            }
            return "USAGE WINDOW"
        }
    }

    /// A quota whose provider contract explicitly identifies model scope.
    /// A label or secondary flag alone is not proof: Codex uses the same shape
    /// for model lanes and other metered features, while MiniMax's video lane
    /// is a modality category rather than a named model.
    static func isModelWindow(
        _ window: UsageWindow,
        providerId: String? = nil
    ) -> Bool {
        guard window.secondary else { return false }
        let id = window.id.lowercased()
        let providerContractMatch: Bool
        switch providerId?.lowercased() {
        case "codex":
            providerContractMatch = id == "codex_bengalfox_session"
                || id == "codex_bengalfox_weekly"
        case "cursor":
            providerContractMatch = id == "plan_auto" || id == "plan_api"
        default:
            providerContractMatch = false
        }

        return providerContractMatch
            || id == "weekly_sonnet"
            || id == "weekly_opus"
            || id.hasPrefix("weekly_scoped_")
    }

    static func sortedWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted {
            let left = sortRank($0)
            let right = sortRank($1)
            if left != right { return left < right }
            return title(for: $0).localizedCaseInsensitiveCompare(title(for: $1)) == .orderedAscending
        }
    }

    /// Hidden-widget VoiceOver copy must not include the account label.
    static let hiddenUsageAccessibilityLabel = "Usage values hidden"

    /// Settings promises the provider identity remains visible when values
    /// are hidden. Use the registry display name, never a user-supplied label.
    static func hiddenWidgetProviderTitle(account: AccountRef?, providerId: String) -> String {
        if let account { return account.displayName }
        return ProviderRegistry.spec(for: providerId)?.displayName ?? "Vigil"
    }

    static func hiddenUsageAccessibilityLabel(providerDisplayName: String?) -> String {
        guard let providerDisplayName, !providerDisplayName.isEmpty else {
            return hiddenUsageAccessibilityLabel
        }
        return "\(providerDisplayName). \(hiddenUsageAccessibilityLabel)"
    }

    static func accountTitle(_ account: AccountRef) -> String {
        guard let label = account.label?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !label.isEmpty else {
            return account.displayName
        }
        return "\(account.displayName) · \(label)"
    }

    /// Provider plan identifiers are often lowercase machine values. Normalize
    /// only known whole values and preserve every unknown string verbatim so
    /// names such as ChatGPT, API, or mixed-case product tiers are not damaged.
    static func planTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return value
        }
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

    /// Shared glanceable status used by Home, account detail, and widgets.
    static func surfaceStatusTitle(
        snapshot: ProviderSnapshot?,
        at evaluatedAt: Date = Date()
    ) -> String {
        guard let snapshot else { return "Waiting" }
        if snapshot.status == .ok,
           SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: evaluatedAt) {
            return "Awaiting update"
        }
        if snapshot.status == .ok,
           SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, at: evaluatedAt) {
            return "Stale"
        }
        return statusTitle(snapshot.status)
    }

    static func treatsPercentageAsLive(
        snapshot: ProviderSnapshot,
        at evaluatedAt: Date = Date()
    ) -> Bool {
        snapshot.status == .ok
            && !SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, at: evaluatedAt)
            && !SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: evaluatedAt)
    }

    static func planTierContext(plan: String?, treatsPercentageAsLive: Bool) -> String? {
        let value = plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        let title = planTitle(value)
        if treatsPercentageAsLive {
            return "The displayed \(title) plan identifies the allowance tier, and the live percentage already reflects that tier."
        }
        return "The displayed \(title) plan identifies the allowance tier. The percentage is from the last accepted reading."
    }

    static func acceptedFreshnessPrefix(resetPending: Bool, stale: Bool) -> String {
        if resetPending {
            return "Reset passed, awaiting provider update. Last checked "
        }
        if stale {
            return "Stale. Last checked "
        }
        return "Checked "
    }

    static func circularDegradedAccessibilitySuffix(
        snapshot: ProviderSnapshot,
        at date: Date = Date()
    ) -> String {
        let title = surfaceStatusTitle(snapshot: snapshot, at: date)
        if title == "Live" { return "" }
        return ", \(title.lowercased())"
    }

    static func limitSourceNote(
        snapshot: ProviderSnapshot?,
        accountPlan: String?,
        at evaluatedAt: Date = Date()
    ) -> String {
        let exactCount = snapshot?.windows.filter {
            $0.used != nil && $0.limit != nil
        }.count ?? 0
        let differingAmountBaseCount = snapshot?.windows.filter {
            $0.used != nil
                && $0.limit != nil
                && !exactAmountsMatchUtilization($0)
        }.count ?? 0
        let windowCount = snapshot?.windows.count ?? 0
        let metricCount = snapshot?.metrics.count ?? 0
        let plan = snapshot?.planLabel ?? accountPlan
        let live = snapshot.map { treatsPercentageAsLive(snapshot: $0, at: evaluatedAt) } ?? false
        let planContext = planTierContext(plan: plan, treatsPercentageAsLive: live)

        if let snapshot, SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: evaluatedAt) {
            return "One or more provider resets have passed. Vigil hides those old values until a provider update confirms the new usage. Other unexpired limits and metrics remain visible."
        }
        if snapshot == nil {
            return "Vigil has no accepted provider reading for this account yet."
        }
        if snapshot?.status != .ok {
            if windowCount > 0 {
                let retainedSource = exactCount > 0
                    ? "It included exact amounts for at least one quota."
                    : "It included percentages and reset times, but no absolute token or message ceiling."
                let tier = exactCount == 0
                    ? planContext.map { " \($0)" } ?? ""
                    : ""
                return "These values are retained from the last accepted provider reading. \(retainedSource)\(tier)"
            }
            if metricCount > 0 {
                return "These balances or account metrics are retained from the last accepted provider reading."
            }
            return "Vigil has no accepted quota or metric reading for this account. The latest provider check was not accepted."
        }
        if windowCount == 0, metricCount > 0 {
            return "This provider currently reports balances or account metrics rather than a reset quota."
        }
        if windowCount == 0 {
            return "The provider accepted this account but did not report a finite quota or balance."
        }
        if differingAmountBaseCount > 0 {
            return "This provider reports both a quota percentage and exact amount fields, but at least one amount ratio uses a different allowance base. Vigil preserves and labels both instead of forcing them into one calculation."
        }
        if exactCount == windowCount {
            return "This provider supplied both used and limit values for every current quota."
        }
        if exactCount > 0 {
            return "This provider supplied exact amounts for some quotas and percentages for the others."
        }
        let source = "This provider supplied quota percentages and reset times, but no absolute token or message ceiling."
        let tier = planContext.map { " \($0) Vigil does not invent a fixed denominator from the plan name alone." } ?? ""
        return source + tier
    }

    /// Freshness-line prefix for a degraded snapshot, completed by a relative
    /// timestamp ("Provider changed, data from 3 hr ago"). On a degraded
    /// snapshot `fetchedAt` is when the shown data was last accepted, not the
    /// last poll attempt — polls may still run every minute — so the line ages
    /// the data and never claims a check time.
    static func retainedFreshnessPrefix(_ status: SnapshotStatus) -> String {
        statusTitle(status) + ", data from "
    }

    /// Freshness clause for a card's spoken accessibility summary, which
    /// replaces the card's visible children for VoiceOver. Same honesty rule
    /// as the visible line: an ok snapshot's `fetchedAt` is a real check
    /// time; a degraded snapshot's `fetchedAt` is when the shown data was
    /// last accepted, while checks may still run every minute — so the
    /// spoken clause ages the data and never claims a check time.
    static func accessibilityFreshness(status: SnapshotStatus, fetchedAt: Date) -> String {
        let stamp = fetchedAt.formatted(date: .abbreviated, time: .shortened)
        return status == .ok ? "Last checked \(stamp)" : "Data from \(stamp)"
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
