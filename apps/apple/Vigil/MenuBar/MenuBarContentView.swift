#if os(macOS)
import SwiftUI
import VigilKit

/// Compact dashboard for the menu bar window (M7).
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.accounts.isEmpty {
                Text("No accounts linked — open Vigil to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts) { account in
                    MenuBarAccountRow(
                        account: account,
                        snapshot: model.snapshots[account.key],
                        nextAllowed: model.nextAllowed[account.key]
                    )
                }
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
        .frame(width: 300)
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
                Text(account.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let snapshot, snapshot.status != .ok {
                    Text(statusText(snapshot.status))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if let snapshot {
                ForEach(snapshot.windows.filter { !$0.secondary }, id: \.id) { window in
                    HStack(spacing: 6) {
                        Text(window.id == "session" ? "Session" : "Weekly")
                            .font(.caption)
                            .frame(width: 52, alignment: .leading)
                        Gauge(value: min(max(window.utilization, 0), 100), in: 0...100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(UsageTint.color(for: window.utilization))
                        Text("\(Int(window.utilization.rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                HStack(spacing: 4) {
                    if snapshot.fetchedAt > .distantPast {
                        Text("Updated")
                        Text(snapshot.fetchedAt, style: .relative)
                        Text("ago")
                    } else {
                        Text("No successful update yet")
                    }
                    if let nextAllowed, nextAllowed > .now, snapshot.status == .rateLimited {
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
#endif
