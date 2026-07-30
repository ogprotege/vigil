import SwiftUI
import VigilKit

struct AccountLimitSummary: Identifiable {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let evaluatedAt: Date

    init(
        account: AccountRef,
        snapshot: ProviderSnapshot?,
        nextAllowed: Date?,
        evaluatedAt: Date = Date()
    ) {
        self.account = account
        self.snapshot = snapshot
        self.nextAllowed = nextAllowed
        self.evaluatedAt = evaluatedAt
    }

    var id: String { account.id }

    var resetPending: Bool {
        snapshot.map {
            SnapshotFreshness.hasUnconfirmedReset(in: $0, at: evaluatedAt)
        } ?? false
    }

    var decisiveWindow: UsageWindow? {
        guard let snapshot else { return nil }
        return SnapshotFreshness.confirmedWindows(
            in: snapshot,
            at: evaluatedAt
        ).min {
            let left = UsagePresentation.remainingPercent(for: $0)
            let right = UsagePresentation.remainingPercent(for: $1)
            if left != right { return left < right }
            return UsagePresentation.title(for: $0)
                .localizedCaseInsensitiveCompare(UsagePresentation.title(for: $1)) == .orderedAscending
        }
    }

    var decisiveMetric: UsageMetric? {
        snapshot?.metrics.sorted {
            metricRank($0) < metricRank($1)
        }.first
    }

    /// The Home screen is an urgency list, not a connectivity-status list.
    /// Authentication and schema failures need intervention first. A current,
    /// finite quota then outranks passive freshness problems so a known 1%-left
    /// limit cannot sit below an offline or merely stale account. Healthy
    /// balance-only accounts are useful, but have no finite quota to rank.
    var actionRank: Int {
        guard let snapshot else { return 2 }
        switch snapshot.status {
        case .authExpired, .schemaChanged:
            return 0
        case .ok:
            let stale = SnapshotFreshness.isStale(
                fetchedAt: snapshot.fetchedAt,
                at: evaluatedAt
            )
            if !stale, decisiveWindow != nil {
                return 1
            }
            if resetPending || stale {
                return 2
            }
            return 3
        case .network, .rateLimited:
            return 2
        }
    }

    var remainingRank: Double {
        decisiveWindow.map(UsagePresentation.remainingPercent) ?? 101
    }

    /// Orders the non-blocking degraded/unknown bucket without allowing it to
    /// jump ahead of a current finite quota. A passed reset is the most useful
    /// retry cue, followed by retained finite quota data, then accounts with no
    /// accepted finite reading.
    private var degradedRank: Int {
        if resetPending { return 0 }
        if decisiveWindow != nil { return 1 }
        if snapshot != nil { return 2 }
        return 3
    }

    private var blockingRank: Int {
        switch snapshot?.status {
        case .authExpired: return 0
        case .schemaChanged: return 1
        default: return 2
        }
    }

    var displayStatusTitle: String {
        guard let snapshot else { return "Waiting" }
        if snapshot.status == .ok, resetPending { return "Awaiting update" }
        if snapshot.status == .ok, SnapshotFreshness.isStale(
            fetchedAt: snapshot.fetchedAt,
            at: evaluatedAt
        ) {
            return "Stale"
        }
        return UsagePresentation.statusTitle(snapshot.status)
    }

    var displayStatusSymbol: String? {
        guard let snapshot else { return "clock" }
        if snapshot.status == .ok, resetPending { return "arrow.clockwise.circle" }
        if snapshot.status == .ok, SnapshotFreshness.isStale(
            fetchedAt: snapshot.fetchedAt,
            at: evaluatedAt
        ) {
            return "clock.badge.exclamationmark"
        }
        return UsagePresentation.statusSymbol(snapshot.status)
    }

    static func ranked(
        accounts: [AccountRef],
        snapshots: [String: ProviderSnapshot],
        nextAllowed: [String: Date],
        evaluatedAt: Date = Date()
    ) -> [AccountLimitSummary] {
        return accounts.map {
            AccountLimitSummary(
                account: $0,
                snapshot: snapshots[$0.key],
                nextAllowed: nextAllowed[$0.key],
                evaluatedAt: evaluatedAt
            )
        }
        .sorted {
            if $0.actionRank != $1.actionRank { return $0.actionRank < $1.actionRank }
            if $0.actionRank == 0, $0.blockingRank != $1.blockingRank {
                return $0.blockingRank < $1.blockingRank
            }
            if $0.actionRank == 1, $0.remainingRank != $1.remainingRank {
                return $0.remainingRank < $1.remainingRank
            }
            if $0.actionRank == 2, $0.degradedRank != $1.degradedRank {
                return $0.degradedRank < $1.degradedRank
            }
            if $0.actionRank == 2, $0.remainingRank != $1.remainingRank {
                return $0.remainingRank < $1.remainingRank
            }
            let left = $0.snapshot?.fetchedAt ?? .distantPast
            let right = $1.snapshot?.fetchedAt ?? .distantPast
            if left != right { return left < right }
            return $0.account.key < $1.account.key
        }
    }

    private func metricRank(_ metric: UsageMetric) -> Int {
        let secondary = metric.secondary ? 10 : 0
        switch metric.kind {
        case .remaining: return secondary
        case .balance: return secondary + 1
        case .spend: return secondary + 2
        case .limit: return secondary + 3
        }
    }
}

struct AccountLimitSummaryCard: View {
    let summary: AccountLimitSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var snapshot: ProviderSnapshot? { summary.snapshot }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    decisiveValue
                    if snapshot != nil { freshness }
                    openCue
                }
            } else {
                HStack(alignment: .center, spacing: 15) {
                    reserveMark
                    VStack(alignment: .leading, spacing: 7) {
                        identity
                        decisiveValue
                        if snapshot != nil { freshness }
                    }
                    Spacer(minLength: 6)
                    openCue
                }
            }
        }
        .padding(VigilSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VigilPalette.surface.opacity(0.97),
            in: RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
                .stroke(cardTint.opacity(0.32), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens all limits and account details")
    }

    @ViewBuilder
    private var identity: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                VigilProviderMark(
                    providerId: summary.account.providerId,
                    displayName: summary.account.displayName,
                    size: 38
                )
                identityCopy
                statusPill
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                identityCopy
                Spacer(minLength: 4)
                statusPill
            }
        }
    }

    private var identityCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(UsagePresentation.accountTitle(summary.account))
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let plan = snapshot?.planLabel ?? summary.account.plan, !plan.isEmpty {
                Text(UsagePresentation.planTitle(plan))
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if snapshot != nil {
            VigilStatusPill(
                text: summary.displayStatusTitle,
                color: cardTint,
                symbol: summary.displayStatusSymbol
            )
        } else {
            VigilStatusPill(
                text: "Waiting",
                color: VigilPalette.inkMuted,
                symbol: "clock"
            )
        }
    }

    @ViewBuilder
    private var decisiveValue: some View {
        if dynamicTypeSize.isAccessibilitySize, summary.decisiveWindow != nil {
            reserveMark
        }

        if let window = summary.decisiveWindow {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Int(UsagePresentation.remainingPercent(for: window).rounded()))% left")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(UsageTint.color(for: window.utilization))
                Text(UsagePresentation.title(for: window))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                if isCurrent {
                    ResetCountdownView(resetsAt: window.resetsAt)
                } else {
                    Text(resetDateText(window.resetsAt))
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
        } else if let metric = summary.decisiveMetric {
            VStack(alignment: .leading, spacing: 3) {
                Text(MetricFormat.value(metric))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(metric.kind == .spend ? VigilPalette.caution : VigilPalette.safe)
                Text(metric.label)
                    .font(.subheadline)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        } else {
            Text(emptyValueText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reserveMark: some View {
        Group {
            if let window = summary.decisiveWindow {
                ReserveDial(
                    remaining: UsagePresentation.remainingPercent(for: window),
                    tint: UsageTint.color(for: window.utilization)
                )
            } else {
                VigilProviderMark(
                    providerId: summary.account.providerId,
                    displayName: summary.account.displayName,
                    size: 64
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var freshness: some View {
        SnapshotFreshnessLine(snapshot: snapshot, nextAllowed: summary.nextAllowed)
    }

    private var openCue: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(VigilPalette.inkFaint)
            .accessibilityHidden(true)
    }

    private var isCurrent: Bool {
        guard let snapshot else { return false }
        return snapshot.status == .ok
            && !summary.resetPending
            && !SnapshotFreshness.isStale(
                fetchedAt: snapshot.fetchedAt,
                at: summary.evaluatedAt
            )
    }

    private var cardTint: Color {
        guard let snapshot else { return VigilPalette.inkMuted }
        if snapshot.status == .ok, summary.resetPending {
            return VigilPalette.caution
        }
        if snapshot.status == .ok, SnapshotFreshness.isStale(
            fetchedAt: snapshot.fetchedAt,
            at: summary.evaluatedAt
        ) {
            return VigilPalette.caution
        }
        return VigilPalette.statusColor(snapshot.status)
    }

    private var accessibilitySummary: String {
        var parts = [UsagePresentation.accountTitle(summary.account)]
        if let plan = snapshot?.planLabel ?? summary.account.plan, !plan.isEmpty {
            parts.append("Plan \(UsagePresentation.planTitle(plan))")
        }
        if snapshot != nil {
            parts.append(summary.displayStatusTitle)
        } else {
            parts.append("Waiting for the first provider check")
        }
        if let window = summary.decisiveWindow {
            parts.append("\(Int(UsagePresentation.remainingPercent(for: window).rounded())) percent left")
            parts.append(UsagePresentation.title(for: window))
            parts.append(resetDateText(window.resetsAt))
        } else if let metric = summary.decisiveMetric {
            parts.append("\(metric.label), \(MetricFormat.value(metric))")
        } else if snapshot != nil {
            parts.append(emptyValueText)
        }
        if let snapshot, snapshot.fetchedAt > .distantPast {
            parts.append(
                UsagePresentation.accessibilityFreshness(
                    status: snapshot.status,
                    fetchedAt: snapshot.fetchedAt
                )
            )
        }
        if let nextAllowed = summary.nextAllowed, nextAllowed > Date() {
            parts.append(
                "Next provider check \(nextAllowed.formatted(date: .omitted, time: .shortened))"
            )
        }
        return parts.joined(separator: ", ")
    }

    private var emptyValueText: String {
        guard let snapshot else { return "Waiting for the first check" }
        guard snapshot.status == .ok else {
            return "No accepted provider reading yet"
        }
        if summary.resetPending {
            return "Limit reset · awaiting provider update"
        }
        return "Provider reports no finite quota"
    }

    private func resetDateText(_ date: Date?) -> String {
        guard let date else { return "No reset reported" }
        return "Provider reset \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
