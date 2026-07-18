import SwiftUI
import VigilKit

/// One account: plan chip, session gauge, weekly bars (model sub-quotas
/// behind a disclosure), ticking reset countdowns, staleness tint, and
/// honest per-status banners.
struct AccountCardView: View {
    let account: AccountRef
    let snapshot: ProviderSnapshot?
    let nextAllowed: Date?
    let relink: () -> Void

    @State private var showSecondary = false

    private var session: UsageWindow? {
        snapshot?.windows.first { $0.id == "session" }
    }

    private var weekly: UsageWindow? {
        snapshot?.windows.first { $0.id == "weekly" }
    }

    private var secondaryWindows: [UsageWindow] {
        snapshot?.windows.filter(\.secondary) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusBanner
            if let snapshot, !snapshot.windows.isEmpty {
                if let session {
                    WindowGaugeRow(title: "Session", window: session, prominent: true)
                }
                if let weekly {
                    WindowBarRow(title: "Weekly", window: weekly)
                }
                if !secondaryWindows.isEmpty {
                    DisclosureGroup(isExpanded: $showSecondary) {
                        VStack(spacing: 8) {
                            ForEach(secondaryWindows, id: \.id) { window in
                                WindowBarRow(title: secondaryTitle(window.id), window: window)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Model limits")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                footer
            } else {
                Text("No usage data yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(account.displayName)
                .font(.headline)
            if let plan = snapshot?.planLabel ?? account.plan {
                Text(plan.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Spacer()
            if let label = account.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
                    tint: .orange,
                    text: nextAllowed.map { "Rate limited — next check at \($0.formatted(date: .omitted, time: .shortened))" }
                        ?? "Rate limited — backing off"
                )
            case .authExpired:
                HStack {
                    StatusBannerView(icon: "key.slash", tint: .red, text: "Sign-in expired")
                    Spacer()
                    Button("Re-link", action: relink)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .schemaChanged:
                StatusBannerView(icon: "exclamationmark.triangle", tint: .yellow,
                                 text: "\(account.displayName) changed something — check for a Vigil update")
            case .network:
                StatusBannerView(icon: "wifi.slash", tint: .secondary,
                                 text: snapshot.windows.isEmpty
                                    ? "Offline — couldn't fetch yet"
                                    : "Offline — showing last known data")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let snapshot {
            HStack(spacing: 4) {
                if snapshot.fetchedAt > .distantPast {
                    Text("Updated")
                    Text(snapshot.fetchedAt, style: .relative)
                    Text("ago")
                } else {
                    Text("No successful update yet")
                }
                if let nextAllowed, nextAllowed > .now {
                    Text("· next check at \(nextAllowed.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(Staleness.tint(for: snapshot.fetchedAt))
        }
    }

    private func secondaryTitle(_ id: String) -> String {
        switch id {
        case "weekly_sonnet": return "Sonnet weekly"
        case "weekly_opus": return "Opus weekly"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct StatusBannerView: View {
    let icon: String
    var tint: Color = .secondary
    let text: String

    init(icon: String, tint: Color, text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Staleness is tinted, never hidden (docs/architecture.md).
enum Staleness {
    static func tint(for fetchedAt: Date) -> Color {
        let age = Date().timeIntervalSince(fetchedAt)
        if age > 3600 { return .orange }
        if age > 1800 { return .yellow }
        return .secondary
    }
}
