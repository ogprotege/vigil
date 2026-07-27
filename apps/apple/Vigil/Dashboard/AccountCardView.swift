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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var confirmedWindows: [UsageWindow] {
        guard let snapshot else { return [] }
        return SnapshotFreshness.confirmedWindows(in: snapshot)
    }

    private var resetPending: Bool {
        snapshot.map { SnapshotFreshness.hasUnconfirmedReset(in: $0) } ?? false
    }

    private var currentWindows: [UsageWindow] {
        UsagePresentation.sortedWindows(
            confirmedWindows.filter {
                !UsagePresentation.isModelWindow(
                    $0,
                    providerId: account.providerId
                )
            }
        )
    }

    private var modelWindows: [UsageWindow] {
        UsagePresentation.sortedWindows(
            confirmedWindows.filter {
                UsagePresentation.isModelWindow(
                    $0,
                    providerId: account.providerId
                )
            }
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
                if !currentWindows.isEmpty {
                    windowSection(title: "Current limits", windows: currentWindows, snapshot: snapshot)
                }

                if !modelWindows.isEmpty {
                    windowSection(title: "Model caps", windows: modelWindows, snapshot: snapshot)
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

                SnapshotFreshnessLine(snapshot: snapshot, nextAllowed: nextAllowed)
            } else if let snapshot, snapshot.status == .ok {
                StatusBannerView(
                    icon: "infinity",
                    tint: VigilPalette.signal,
                    text: "This provider reports no finite usage limits."
                )
                SnapshotFreshnessLine(snapshot: snapshot, nextAllowed: nextAllowed)
            } else if snapshot == nil {
                waitingState
            }
            // Remaining empty snapshots are degraded; statusBanner explains
            // authExpired / network / schemaChanged without claiming Live.
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
                Text(account.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if ProviderPresentation.isExperimental(providerId: account.providerId) {
                    ExperimentalBadge()
                }
                if let label = account.label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accountStatus
                if let plan = snapshot?.planLabel ?? account.plan, !plan.isEmpty {
                    Text(UsagePresentation.planTitle(plan))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VigilPalette.signal)
                }
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if let snapshot {
            if snapshot.status == .ok, resetPending {
                VigilStatusPill(
                    text: "Awaiting update",
                    color: VigilPalette.caution,
                    symbol: "arrow.clockwise.circle"
                )
            } else if SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt), snapshot.status == .ok {
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
                if resetPending {
                    StatusBannerView(
                        icon: "arrow.clockwise.circle",
                        tint: VigilPalette.caution,
                        text: "A provider reset passed. Vigil hid the old value until the next provider update."
                    )
                }
            case .rateLimited:
                StatusBannerView(
                    icon: "hourglass",
                    tint: VigilPalette.caution,
                    text: nextAllowed.map {
                        "Provider cooldown · next check at \($0.formatted(date: .omitted, time: .shortened))"
                    } ?? "Provider cooldown is active"
                )
            case .authExpired:
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            expiredBanner
                            relinkButton
                        }
                    } else {
                        HStack(spacing: 10) {
                            expiredBanner
                            relinkButton
                        }
                    }
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
                        : "Offline. Showing the last known provider values."
                )
            }
        }
    }

    private var expiredBanner: some View {
                    StatusBannerView(
                        icon: "key.slash",
                        tint: VigilPalette.critical,
                        text: "This sign-in expired."
                    )
    }

    private var relinkButton: some View {
        Button(action: relink) {
            Text("Re-link")
                .frame(minHeight: 44)
        }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .controlSize(.small)
            .accessibilityIdentifier("vigil.account.relink")
    }

    private func windowSection(
        title: String,
        windows: [UsageWindow],
        snapshot: ProviderSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
            LimitMeterStack(
                windows: windows,
                status: snapshot.status,
                fetchedAt: snapshot.fetchedAt
            )
        }
    }

    private func metricSection(title: String, metrics: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: VigilSpacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
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

    private var waitingState: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { waitingContent }
            } else {
                HStack(spacing: 12) { waitingContent }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilInsetSurface()
    }

    @ViewBuilder
    private var waitingContent: some View {
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
        .fixedSize(horizontal: false, vertical: true)
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
