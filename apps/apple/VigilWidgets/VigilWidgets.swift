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
        AppIntentConfiguration(
            kind: "app.vigil.usage",
            intent: SelectUsageAccountIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Monitor a selected account's limits, spend, or balance.")
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
                } else if let metric = snapshot.metrics.first(where: { !$0.secondary })
                    ?? snapshot.metrics.first {
                    HStack {
                        Image(systemName: metricSymbol(metric.kind))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(metricValue(metric))
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)
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
                    .foregroundStyle(
                        SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, at: entry.date)
                            ? .orange : .secondary
                    )
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

/// Lock-screen circular: session percentage ring. Failed fetches deliberately
/// preserve the last good windows, so this family carries the same degradation
/// signals as systemSmall (status != ok, or data older than the shared
/// 30-minute staleness threshold): degraded tint, a compact warning marker,
/// and an accessibility label that says the data may be out of date.
struct CircularUsageView: View {
    let entry: UsageEntry

    private var degraded: Bool {
        guard let snapshot = entry.snapshot else { return false }
        return SnapshotFreshness.isDegraded(
            status: snapshot.status,
            fetchedAt: snapshot.fetchedAt,
            at: entry.date
        )
    }

    private var degradedSuffix: String {
        degraded ? ", data may be out of date" : ""
    }

    var body: some View {
        if let session = entry.snapshot?.windows.first(where: { $0.id == "session" }) {
            Gauge(value: min(max(session.utilization, 0), 100), in: 0...100) {
                Text(providerLetter)
            } currentValueLabel: {
                // The marker lives in the center label because the capacity
                // gauge style is the only part guaranteed to render at every
                // lock-screen rendering mode.
                VStack(spacing: 0) {
                    Text("\(Int(session.utilization.rounded()))")
                    if degraded {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(degraded ? Color.orange : nil)
            .widgetAccentable()
            .accessibilityLabel(Text("\(entry.account?.displayName ?? "Vigil") session, \(Int(session.utilization.rounded())) percent used\(degradedSuffix)"))
        } else if let metric = entry.snapshot?.metrics.first(where: { !$0.secondary })
            ?? entry.snapshot?.metrics.first {
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    Text(providerLetter)
                        .font(.caption2)
                    if degraded {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
                .foregroundStyle(degraded ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                Text(compactMetricValue(metric))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(entry.account?.displayName ?? "Vigil"), \(metric.label)\(degradedSuffix)"))
            .accessibilityValue(Text(metricValue(metric)))
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
        case "openrouter": return "O"
        case "deepseek": return "D"
        case .some(let id):
            // New providers fall back to the first letter of their registry
            // display name, matching the menu bar title convention.
            guard let first = ProviderRegistry.spec(for: id)?.displayName.first else {
                return "V"
            }
            return String(first)
        case nil: return "V"
        }
    }
}

private func metricValue(_ metric: UsageMetric) -> String {
    if let unit = metric.unit, unit.count == 3 {
        return metric.value.formatted(
            .currency(code: unit).precision(.fractionLength(0...3))
        )
    }
    let value = metric.value.formatted(
        .number.precision(.fractionLength(0...3))
    )
    return metric.unit.map { "\(value) \($0)" } ?? value
}

private func metricSymbol(_ kind: UsageMetricKind) -> String {
    switch kind {
    case .spend: return "creditcard"
    case .balance, .remaining: return "wallet.pass"
    case .limit: return "gauge.with.needle"
    }
}

private func compactMetricValue(_ metric: UsageMetric) -> String {
    let value = metric.value.formatted(
        .number.notation(.compactName).precision(.significantDigits(1...3))
    )
    guard let unit = metric.unit else { return value }
    return unit == "USD" ? "$\(value)" : "\(value) \(unit)"
}
