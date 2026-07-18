import SwiftUI
import VigilKit
import WidgetKit

@main
struct VigilWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.vigil.usage", provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Session and weekly limits with a live reset countdown.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularUsageView(entry: entry)
        default:
            SmallUsageView(entry: entry)
        }
    }
}

/// Home-screen small: session ring, weekly bar, ticking countdown,
/// staleness tinted, never hidden.
struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.account?.displayName ?? snapshot.providerId.capitalized)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if snapshot.status != .ok {
                        Image(systemName: statusSymbol(snapshot.status))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let session = snapshot.windows.first(where: { $0.id == "session" }) {
                    HStack(spacing: 8) {
                        Gauge(value: min(max(session.utilization, 0), 100), in: 0...100) {
                            EmptyView()
                        } currentValueLabel: {
                            Text("\(Int(session.utilization.rounded()))")
                                .font(.system(.headline, design: .rounded))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let resetsAt = session.resetsAt, resetsAt > entry.date {
                                Text(timerInterval: entry.date...resetsAt, countsDown: true)
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if let weekly = snapshot.windows.first(where: { $0.id == "weekly" }) {
                    Gauge(value: min(max(weekly.utilization, 0), 100), in: 0...100) {
                        Text("Wk \(Int(weekly.utilization.rounded()))%")
                            .font(.caption2)
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                }
                Text(snapshot.fetchedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(entry.date.timeIntervalSince(snapshot.fetchedAt) > 1800 ? .orange : .secondary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                // An account with no snapshot yet is linked, just unfetched —
                // don't tell a linked user to link.
                Text(entry.account == nil ? "Link an account in Vigil" : "Waiting for first fetch")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(_ status: SnapshotStatus) -> String {
        switch status {
        case .rateLimited: return "hourglass"
        case .authExpired: return "key.slash"
        case .schemaChanged: return "exclamationmark.triangle"
        case .network: return "wifi.slash"
        case .ok: return "checkmark"
        }
    }
}

/// Lock-screen circular: session percentage ring.
struct CircularUsageView: View {
    let entry: UsageEntry

    var body: some View {
        if let session = entry.snapshot?.windows.first(where: { $0.id == "session" }) {
            Gauge(value: min(max(session.utilization, 0), 100), in: 0...100) {
                Text(providerLetter)
            } currentValueLabel: {
                Text("\(Int(session.utilization.rounded()))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            Gauge(value: 0, in: 0...100) {
                Text("V")
            } currentValueLabel: {
                Image(systemName: "link")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
    }

    private var providerLetter: String {
        switch entry.snapshot?.providerId {
        case "claude": return "C"
        case "codex": return "X"
        default: return "V"
        }
    }
}
