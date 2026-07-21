import Foundation
import VigilKit

/// Home period filter — token-monitor's DAY / MONTH / TOTAL, expanded to the
/// five ranges Vigil users asked for. Maps onto provider windows honestly:
/// Day ≈ session/rolling, Week ≈ weekly, Month ≈ monthly, Year ≈ longest
/// available plan window, Lifetime ≈ everything including metrics.
enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year
    case lifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .lifetime: return "Life"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .lifetime: return "Lifetime"
        }
    }

    /// Windows that belong in this period's home summary.
    func matches(_ window: UsageWindow) -> Bool {
        let id = window.id.lowercased()
        switch self {
        case .day:
            return id == "session" || id.hasPrefix("session_")
                || (window.windowSeconds.map { $0 > 0 && $0 <= 86_400 } ?? false)
        case .week:
            return id == "weekly" || id.hasPrefix("weekly_")
                || (window.windowSeconds.map { $0 > 86_400 && $0 <= 604_800 } ?? false)
        case .month:
            return id == "monthly" || id == "billing" || id == "plan"
                || (window.windowSeconds.map { $0 > 604_800 && $0 <= 2_678_400 } ?? false)
        case .year:
            // Providers rarely expose a true year window — surface the longest
            // primary caps (monthly/plan/billing) and any multi-month lane.
            return id == "monthly" || id == "billing" || id == "plan"
                || (window.windowSeconds.map { $0 > 2_678_400 } ?? false)
        case .lifetime:
            return true
        }
    }

    func filteredWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        let matched = windows.filter(matches)
        if !matched.isEmpty { return UsagePresentation.sortedWindows(matched) }
        // Fall back to primary windows so a Day filter on a weekly-only
        // provider still shows something useful.
        if self != .lifetime {
            let primary = windows.filter { !UsagePresentation.isSpecialWindow($0) }
            if !primary.isEmpty { return UsagePresentation.sortedWindows(primary) }
        }
        return UsagePresentation.sortedWindows(windows)
    }
}

/// Compact hero summary for the selected period across linked accounts.
struct PeriodHeroSummary: Equatable {
    var title: String
    var primaryValue: String
    var secondaryValue: String?
    var detail: String
}

enum PeriodHero {
    static func summary(
        period: UsagePeriod,
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot],
        observations: [UsageObservation] = [],
        now: Date = Date()
    ) -> PeriodHeroSummary {
        if accounts.isEmpty {
            return PeriodHeroSummary(
                title: "Limits",
                primaryValue: "—",
                secondaryValue: nil,
                detail: "Add an account to start watching."
            )
        }

        let candidates = accounts.compactMap { account -> LimitCandidate? in
            guard let snapshot = snapshots[account.key] else { return nil }
            let windows = period.filteredWindows(snapshot.windows)
            guard let window = windows.min(by: {
                UsagePresentation.remainingPercent(for: $0)
                    < UsagePresentation.remainingPercent(for: $1)
            }) else { return nil }
            return LimitCandidate(account: account, snapshot: snapshot, window: window)
        }

        // A quota about to run out outranks a balance. Home exists to surface
        // the tightest limit, so a linked balance-only account (OpenRouter,
        // DeepSeek, xAI) must not displace it — spend rides along in the detail
        // line instead. The spend hero is the fallback for users whose accounts
        // report no windows at all.
        guard let tightest = candidates.min(by: {
            UsagePresentation.remainingPercent(for: $0.window)
                < UsagePresentation.remainingPercent(for: $1.window)
        }) else {
            if let spend = spendSummary(
                period: period,
                accounts: accounts,
                snapshots: snapshots,
                observations: observations,
                now: now
            ) {
                return spend
            }
            return PeriodHeroSummary(
                title: period.accessibilityTitle.uppercased(),
                primaryValue: "—",
                secondaryValue: nil,
                detail: "Waiting for provider limits in this range."
            )
        }

        let remaining = UsagePresentation.remainingPercent(for: tightest.window)
        var detail = "\(UsagePresentation.accountTitle(tightest.account)) · \(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        if let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: period,
            now: now
        ), delta.hasValue {
            detail += " · \(period.accessibilityTitle.lowercased()) spend \(delta.formatted) observed"
        }
        return PeriodHeroSummary(
            title: "Tightest \(period.accessibilityTitle.lowercased()) left",
            primaryValue: "\(Int(remaining.rounded()))%",
            secondaryValue: UsagePresentation.title(for: tightest.window),
            detail: detail
        )
    }

    /// Prefer real spend/balance metrics when the period has observations or
    /// live scalar values — never invent token counts Vigil cannot see.
    private static func spendSummary(
        period: UsagePeriod,
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot],
        observations: [UsageObservation],
        now: Date
    ) -> PeriodHeroSummary? {
        let spendMetrics = accounts.flatMap { account -> [(AccountRef, UsageMetric)] in
            guard let snapshot = snapshots[account.key] else { return [] }
            return snapshot.metrics
                .filter { $0.kind == .spend || $0.kind == .remaining || $0.kind == .balance }
                .map { (account, $0) }
        }
        guard !spendMetrics.isEmpty || !observations.isEmpty else { return nil }

        if period == .lifetime || period == .year || period == .month
            || period == .week || period == .day,
           let delta = UsageObservationStore.spendDelta(
            observations: observations,
            period: period,
            now: now
           ), delta.hasValue {
            return PeriodHeroSummary(
                title: "\(period.accessibilityTitle) spend",
                primaryValue: delta.formatted,
                secondaryValue: delta.unitLabel,
                // Vigil only sees the values a poll returns, so this is spend
                // between the first and last observation inside the range —
                // not the range's true total. Say so rather than implying the
                // 42pt number covers the whole period.
                detail: "Change across the readings Vigil observed on this device in this range."
            )
        }

        // Live remaining / balance as a lifetime-style hero when no history yet.
        if let best = spendMetrics.first(where: { $0.1.kind == .remaining })
            ?? spendMetrics.first(where: { $0.1.kind == .balance })
            ?? spendMetrics.first {
            return PeriodHeroSummary(
                title: best.1.label,
                primaryValue: MetricFormat.value(best.1),
                secondaryValue: best.0.displayName,
                detail: "Live provider value · token totals need local session logs"
            )
        }
        return nil
    }
}
