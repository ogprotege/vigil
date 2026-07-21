#if os(macOS)
import SwiftUI
import VigilKit

/// Compact dashboard for the menu bar window (M7).
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A menu-bar-only session never opens DashboardView, so its
            // storage alert would otherwise stay invisible. Surface the
            // current notice read-only; dismissal stays with the Dashboard
            // alert so the durable-error queue is consumed exactly once.
            if let storageMessage = model.storageErrorMessage {
                MenuBarStorageNoticeRow(message: storageMessage)
            }

            if model.accounts.isEmpty {
                Text("No accounts linked · open Vigil to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.accounts) { account in
                            MenuBarAccountRow(
                                account: account,
                                snapshot: model.snapshots[account.key],
                                nextAllowed: model.nextAllowed[account.key]
                            )
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    Task { await model.refreshAll(surface: "menubar") }
                }
                Spacer()
                Button("Settings…") { openSettings() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        .task {
            // The menu bar app is effectively always-running — keep the
            // ledger-gated timer alive even with no windows open.
            model.startForegroundTimer()
        }
    }
}

private struct MenuBarAccountRow: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(UsagePresentation.accountTitle(account))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if ProviderPresentation.isExperimental(providerId: account.providerId) {
                    ExperimentalBadge()
                }
                Spacer()
                if let snapshot, SnapshotFreshness.isDegraded(
                    status: snapshot.status,
                    fetchedAt: snapshot.fetchedAt
                ) {
                    Text(
                        snapshot.status == .ok
                            ? "stale"
                            : statusText(snapshot.status)
                    )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if let snapshot {
                ForEach(UsagePresentation.sortedWindows(snapshot.windows), id: \.id) { window in
                    HStack(spacing: 6) {
                        Text(UsagePresentation.compactTitle(for: window))
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 78, alignment: .leading)
                        Gauge(
                            value: UsagePresentation.remainingPercent(for: window),
                            in: 0...100
                        ) {
                            EmptyView()
                        }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(UsageTint.color(for: window.utilization))
                        Text(
                            "\(Int(UsagePresentation.remainingPercent(for: window).rounded()))% left"
                        )
                            .font(.caption.monospacedDigit())
                            .frame(width: 58, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text(
                            "\(UsagePresentation.title(for: window)), "
                                + "\(Int(UsagePresentation.remainingPercent(for: window).rounded())) percent left"
                        )
                    )
                }
                // Metrics-only providers (OpenRouter/DeepSeek) expose scalar
                // balances or spend instead of windows — show their values,
                // formatted exactly like the Dashboard's metric rows.
                ForEach(visibleMetrics, id: \.id) { metric in
                    HStack(spacing: 6) {
                        Image(systemName: MetricFormat.symbol(for: metric.kind))
                            .font(.caption)
                            .foregroundStyle(MetricFormat.tint(for: metric.kind))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(metric.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(MetricFormat.value(metric))
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(metric.label))
                    .accessibilityValue(Text(MetricFormat.value(metric)))
                }
                HStack(spacing: 4) {
                    if snapshot.fetchedAt > .distantPast {
                        Text("Updated")
                        Text(snapshot.fetchedAt, style: .relative)
                        Text("ago")
                    } else {
                        Text("No successful update yet")
                    }
                    if let nextAllowed, nextAllowed > .now {
                        Text("· next \(nextAllowed.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Staleness.tint(for: snapshot.fetchedAt))
            } else {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Dashboard convention (AccountCardView): primary metrics inline; if a
    /// provider only reports secondary metrics, show those rather than
    /// nothing — the menu bar has no disclosure group to hide them behind.
    private var visibleMetrics: [UsageMetric] {
        guard let snapshot else { return [] }
        let primary = snapshot.metrics.filter { !$0.secondary }
        return primary.isEmpty ? snapshot.metrics : primary
    }

    private func statusText(_ status: SnapshotStatus) -> String {
        switch status {
        case .ok: return ""
        case .rateLimited: return "rate limited"
        case .authExpired: return "re-link needed"
        case .schemaChanged: return "provider changed"
        case .network: return "offline"
        }
    }
}

/// A visible, read-only mirror of the app's storage alert for menu-bar-only
/// sessions. Persistence failures are product failures (CLAUDE.md) — they
/// must not be invisible just because the main window never opened.
private struct MenuBarStorageNoticeRow: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Vigil couldn't save data", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open the Vigil window to review and dismiss.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Storage problem"))
        .accessibilityValue(Text("\(message) Open the Vigil window to review and dismiss."))
    }
}
#endif
