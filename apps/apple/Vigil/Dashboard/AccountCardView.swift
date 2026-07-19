import SwiftUI
import VigilKit

/// A complete account instrument. Every provider-reported window is visible:
/// rolling, weekly, plan, monthly, and special-model limits all share the same
/// honest "left / used / reset" language.
struct AccountCardView: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let relink: () -> Void

    private var primaryWindows: [UsageWindow] {
        UsagePresentation.sortedWindows(
            snapshot?.windows.filter { !UsagePresentation.isSpecialWindow($0) } ?? []
        )
    }

    private var specialWindows: [UsageWindow] {
        UsagePresentation.sortedWindows(
            snapshot?.windows.filter(UsagePresentation.isSpecialWindow) ?? []
        )
    }

    private var primaryMetrics: [UsageMetric] {
        snapshot?.metrics.filter { !$0.secondary } ?? []
    }

    private var secondaryMetrics: [UsageMetric] {
        snapshot?.metrics.filter(\.secondary) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            header
            statusBanner

            if let snapshot, (!snapshot.windows.isEmpty || !snapshot.metrics.isEmpty) {
                if !primaryWindows.isEmpty {
                    limitGrid(primaryWindows)
                }

                if !specialWindows.isEmpty {
                    VStack(alignment: .leading, spacing: VigilSpacing.small) {
                        VigilSectionHeading(
                            "Model and special limits",
                            eyebrow: "Provider quotas",
                            detail: "\(specialWindows.count)"
                        )
                        limitGrid(specialWindows, compact: true)
                    }
                }

                if !primaryMetrics.isEmpty {
                    metricSection(
                        title: snapshot.windows.isEmpty ? "Account balance" : "Account metrics",
                        metrics: primaryMetrics
                    )
                }

                if !secondaryMetrics.isEmpty {
                    metricSection(title: "More account details", metrics: secondaryMetrics)
                }

                footer(snapshot)
            } else {
                waitingState
            }
        }
        .vigilCard(padding: VigilSpacing.medium)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VigilProviderMark(
                providerId: account.providerId,
                displayName: account.displayName
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(account.displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(2)
                    if ProviderPresentation.isExperimental(providerId: account.providerId) {
                        ExperimentalBadge()
                    }
                }
                if let label = account.label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    accountStatus
                    if let plan = snapshot?.planLabel ?? account.plan, !plan.isEmpty {
                        Text(plan.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VigilPalette.signal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(VigilPalette.signal.opacity(0.11), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if let snapshot {
            if SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt), snapshot.status == .ok {
                VigilStatusPill(
                    text: "Stale",
                    color: VigilPalette.caution,
                    symbol: "clock.badge.exclamationmark"
                )
            } else {
                VigilStatusPill(
                    text: UsagePresentation.statusTitle(snapshot.status),
                    color: VigilPalette.statusColor(snapshot.status),
                    symbol: UsagePresentation.statusSymbol(snapshot.status)
                )
            }
        } else {
            VigilStatusPill(
                text: "Waiting",
                color: VigilPalette.inkMuted,
                symbol: "clock"
            )
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let snapshot {
            switch snapshot.status {
            case .ok:
                EmptyView()
            case .rateLimited:
                StatusBannerView(
                    icon: "hourglass",
                    tint: VigilPalette.caution,
                    text: nextAllowed.map {
                        "Provider cooldown · next check at \($0.formatted(date: .omitted, time: .shortened))"
                    } ?? "Provider cooldown is active"
                )
            case .authExpired:
                HStack(spacing: 10) {
                    StatusBannerView(
                        icon: "key.slash",
                        tint: VigilPalette.critical,
                        text: "This sign-in expired."
                    )
                    Button("Re-link", action: relink)
                        .buttonStyle(.borderedProminent)
                        .tint(VigilPalette.signal)
                        .controlSize(.small)
                }
            case .schemaChanged:
                StatusBannerView(
                    icon: "exclamationmark.triangle",
                    tint: VigilPalette.critical,
                    text: "\(account.displayName) changed its usage response. Update Vigil before trusting new values."
                )
            case .network:
                StatusBannerView(
                    icon: "wifi.slash",
                    tint: VigilPalette.inkMuted,
                    text: snapshot.windows.isEmpty && snapshot.metrics.isEmpty
                        ? "Vigil has not reached this provider yet."
                        : "Offline · showing the last known provider values."
                )
            }
        }
    }

    private func limitGrid(_ windows: [UsageWindow], compact: Bool = false) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(windows, id: \.id) { window in
                LimitWindowView(window: window, compact: compact)
            }
        }
    }

    private func metricSection(title: String, metrics: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            VigilSectionHeading(title, eyebrow: "Provider values")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(metrics, id: \.id) { metric in
                    UsageMetricRow(metric: metric)
                }
            }
        }
    }

    private func footer(_ snapshot: ProviderSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.semibold))
            if snapshot.fetchedAt > .distantPast {
                Text("Updated")
                Text(snapshot.fetchedAt, style: .relative)
                Text("ago")
            } else {
                Text("No successful update yet")
            }
            if let nextAllowed, nextAllowed > .now {
                Text("· next check \(nextAllowed.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(Staleness.tint(for: snapshot.fetchedAt))
        .accessibilityElement(children: .combine)
    }

    private var waitingState: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(VigilPalette.signal)
            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for the first provider check")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text("Vigil will show each available limit here.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilInsetSurface()
    }
}

struct StatusBannerView: View {
    let icon: String
    var tint: Color = VigilPalette.inkMuted
    let text: String

    init(icon: String, tint: Color, text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: VigilRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.small)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

/// Uses the shared cross-surface freshness threshold rather than a dashboard-
/// only policy.
enum Staleness {
    static func tint(for fetchedAt: Date) -> Color {
        SnapshotFreshness.isStale(fetchedAt: fetchedAt)
            ? VigilPalette.caution
            : VigilPalette.inkMuted
    }
}
