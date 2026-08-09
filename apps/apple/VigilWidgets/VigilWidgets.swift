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
                .preferredColorScheme(entry.appearance.colorScheme)
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

/// Home-screen small: the tightest window first, then the next provider window.
/// This lets a special-model quota outrank a healthier generic session window.
struct SmallUsageView: View {
    let entry: UsageEntry

    private var degraded: Bool {
        guard let snapshot = entry.snapshot else { return false }
        return SnapshotFreshness.isDegraded(
            status: snapshot.status,
            fetchedAt: snapshot.fetchedAt,
            at: entry.date
        ) || SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: entry.date)
    }

    var body: some View {
        if entry.hidesUsageValues, let snapshot = entry.snapshot {
            privateSummary(snapshot)
        } else if let snapshot = entry.snapshot {
            let resetPending = SnapshotFreshness.hasUnconfirmedReset(
                in: snapshot,
                at: entry.date
            )
            let windows = UsagePresentation.sortedWindows(
                SnapshotFreshness.confirmedWindows(in: snapshot, at: entry.date)
            )
            let tightest = windows.min(by: {
                UsagePresentation.remainingPercent(for: $0)
                    < UsagePresentation.remainingPercent(for: $1)
            })
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(
                        entry.account.map(UsagePresentation.accountTitle)
                            ?? snapshot.providerId.capitalized
                    )
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if degraded {
                        Image(
                            systemName: snapshot.status == .ok
                                ? "clock.badge.exclamationmark"
                                : statusSymbol(snapshot.status)
                        )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let tightest {
                    HStack(spacing: 8) {
                        Gauge(
                            value: UsagePresentation.remainingPercent(for: tightest),
                            in: 0...100
                        ) {
                            EmptyView()
                        } currentValueLabel: {
                            Text(
                                "\(Int(UsagePresentation.remainingPercent(for: tightest).rounded()))%"
                            )
                                .font(.system(.headline, design: .rounded))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                "\(Int(UsagePresentation.remainingPercent(for: tightest).rounded()))% left"
                            )
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            Text(UsagePresentation.compactTitle(for: tightest))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let resetsAt = tightest.resetsAt, resetsAt > entry.date {
                                Text(timerInterval: entry.date...resetsAt, countsDown: true)
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                            }
                        }
                    }
                } else if resetPending {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Limit reset")
                                .font(.caption.weight(.semibold))
                            Text("Awaiting provider update")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
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
                if let second = windows.filter({ $0.id != tightest?.id }).first {
                    HStack(spacing: 4) {
                        Text(UsagePresentation.compactTitle(for: second))
                            .lineLimit(1)
                        Spacer()
                        Text(
                            "\(Int(UsagePresentation.remainingPercent(for: second).rounded()))% left"
                        )
                        .monospacedDigit()
                    }
                    .font(.caption2)
                    Gauge(
                        value: UsagePresentation.remainingPercent(for: second),
                        in: 0...100
                    ) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                }
                // A snapshot for an account whose first fetch failed carries
                // `fetchedAt == .distantPast`, which formats as an absurd
                // multi-millennium age. Every in-app surface guards this; the
                // widget did not.
                Group {
                    if snapshot.fetchedAt > .distantPast {
                        Text(snapshot.fetchedAt, style: .relative)
                    } else {
                        Text("No update yet")
                    }
                }
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

    private func privateSummary(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(
                    entry.account.map(UsagePresentation.accountTitle)
                        ?? snapshot.providerId.capitalized
                )
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                Spacer()
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label("Usage values hidden", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
            Text("Open Vigil to view current limits and account values.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Group {
                if snapshot.fetchedAt > .distantPast {
                    Text(snapshot.fetchedAt, style: .relative)
                } else {
                    Text("No update yet")
                }
            }
            .font(.caption2)
            .foregroundStyle(
                SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt, at: entry.date)
                    ? .orange : .secondary
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(entry.account.map(UsagePresentation.accountTitle) ?? snapshot.providerId.capitalized), usage values hidden"
            )
        )
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

/// Lock-screen circular: tightest-window percentage-left ring. Failed fetches deliberately
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
        ) || SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: entry.date)
    }

    private var degradedSuffix: String {
        degraded ? ", data may be out of date" : ""
    }

    var body: some View {
        if entry.hidesUsageValues, entry.snapshot != nil {
            VStack(spacing: 1) {
                Text(providerLetter)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "eye.slash")
                    .font(.caption.weight(.semibold))
            }
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("\(entry.account?.displayName ?? "Vigil"), usage values hidden")
            )
        } else if let snapshot = entry.snapshot,
           let tightest = SnapshotFreshness.confirmedWindows(
               in: snapshot,
               at: entry.date
           ).min(by: {
            UsagePresentation.remainingPercent(for: $0)
                < UsagePresentation.remainingPercent(for: $1)
        }) {
            Gauge(
                value: UsagePresentation.remainingPercent(for: tightest),
                in: 0...100
            ) {
                Text(providerLetter)
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text(
                        "\(Int(UsagePresentation.remainingPercent(for: tightest).rounded()))%"
                    )
                    Text("left")
                        .font(.system(size: 7, weight: .semibold))
                    if degraded {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(degraded ? Color.orange : nil)
            .widgetAccentable()
            .accessibilityLabel(
                Text(
                    "\(entry.account?.displayName ?? "Vigil") "
                        + "\(UsagePresentation.title(for: tightest)), "
                        + "\(Int(UsagePresentation.remainingPercent(for: tightest).rounded())) percent left"
                        + degradedSuffix
                )
            )
        } else if let snapshot = entry.snapshot,
                  SnapshotFreshness.hasUnconfirmedReset(in: snapshot, at: entry.date) {
            VStack(spacing: 1) {
                Text(providerLetter)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.orange)
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("\(entry.account?.displayName ?? "Vigil"), limit reset, awaiting provider update")
            )
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    UsagePresentation.circularFallbackAccessibilityLabel(
                        accountDisplayName: entry.account?.displayName
                    )
                )
            )
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
            // display name for a stable compact identity.
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
