import SwiftUI
import VigilKit

/// A quota reservoir: the meter and headline both show what remains. The
/// provider still stores utilization internally, and VoiceOver announces both
/// values so the direction of the metric is never ambiguous.
struct LimitWindowView: View {
    let window: UsageWindow
    var compact = false

    private var remaining: Double {
        UsagePresentation.remainingPercent(for: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    VigilEyebrow(text: UsagePresentation.category(for: window))
                    Text(UsagePresentation.title(for: window))
                        .font((compact ? Font.subheadline : Font.body).weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(remaining.rounded()))%")
                        .font(
                            .system(
                                compact ? .title3 : .title2,
                                design: .rounded
                            )
                            .weight(.bold)
                        )
                        .monospacedDigit()
                        .foregroundStyle(UsageTint.color(for: window.utilization))
                    Text("left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }

            LimitReservoirBar(
                remaining: remaining,
                tint: UsageTint.color(for: window.utilization)
            )

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ResetCountdownView(resetsAt: window.resetsAt)
                Spacer()
                Text(usedDescription(window))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(VigilPalette.inkFaint)
            }
        }
        .padding(compact ? 12 : 14)
        .vigilInsetSurface(cornerRadius: VigilRadius.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(UsagePresentation.title(for: window)))
        .accessibilityValue(
            Text(
                "\(Int(remaining.rounded())) percent left, "
                    + accessibilityUsedDescription(window)
            )
        )
        .accessibilityHint(accessibilityCountdown(window.resetsAt))
    }
}

/// A compact stacked limit bar: name (+ optional account) on top, a full-width
/// reservoir, and reset + used underneath. Reads as a clean scannable list,
/// used by the complete account-detail surface.
struct LimitMeterRow: View {
    let window: UsageWindow
    /// Optional context for a row reused across accounts.
    var accountName: String? = nil
    /// Snapshot the window came from, so a row never presents preserved
    /// last-good numbers as current. `UsageService` deliberately keeps the last
    /// good windows on authExpired / network / rateLimited / schemaChanged, so
    /// without this a three-day-old value renders with a live-ticking countdown
    /// and no marker at all.
    var status: SnapshotStatus? = nil
    var fetchedAt: Date? = nil
    /// Keeps community-researched providers visibly labeled when their
    /// model-specific lanes are separated from the account card.
    var isExperimental = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var remaining: Double {
        UsagePresentation.remainingPercent(for: window)
    }

    private var isDegraded: Bool {
        guard let status, let fetchedAt else { return false }
        return SnapshotFreshness.isDegraded(status: status, fetchedAt: fetchedAt)
    }

    private var resetPending: Bool {
        guard let fetchedAt else { return false }
        return SnapshotFreshness.resetIsUnconfirmed(
            for: window,
            fetchedAt: fetchedAt
        )
    }

    var body: some View {
        Group {
            if resetPending {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UsagePresentation.title(for: window))
                            .font(.subheadline.weight(.semibold))
                        Text("Reset passed · awaiting provider update")
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .foregroundStyle(VigilPalette.caution)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    meterHeader

                    LimitReservoirBar(
                        remaining: remaining,
                        tint: UsageTint.color(for: window.utilization)
                    )

                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                resetOrStaleness
                                usedLabel
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                resetOrStaleness
                                Spacer()
                                usedLabel
                            }
                        }
                    }
                }
                .opacity(isDegraded ? 0.7 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        (accountName.map { "\($0), " } ?? "")
                            + UsagePresentation.title(for: window)
                            + (isExperimental ? ", experimental integration" : "")
                    )
                )
                .accessibilityValue(
                    Text(
                        "\(Int(remaining.rounded())) percent left, "
                            + accessibilityUsedDescription(window)
                            + (isDegraded && status != nil && fetchedAt != nil
                                ? ", \(UsagePresentation.stalenessNote(status: status!, fetchedAt: fetchedAt!))"
                                : "")
                    )
                )
                .accessibilityHint(isDegraded ? Text("") : accessibilityCountdown(window.resetsAt))
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var meterHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                titleBlock
                remainingLabel
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                titleBlock
                Spacer(minLength: 8)
                remainingLabel
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(UsagePresentation.title(for: window))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if accountName != nil || isExperimental {
                VStack(alignment: .leading, spacing: 4) {
                    if let accountName {
                        Text(accountName)
                            .font(.caption2)
                            .foregroundStyle(VigilPalette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isExperimental {
                        ExperimentalBadge()
                    }
                }
            }
        }
    }

    private var remainingLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(Int(remaining.rounded()))%")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(UsageTint.color(for: window.utilization))
            Text("left")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    @ViewBuilder
    private var resetOrStaleness: some View {
        if isDegraded, let status, let fetchedAt {
            Label(
                UsagePresentation.stalenessNote(status: status, fetchedAt: fetchedAt),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundStyle(VigilPalette.caution)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ResetCountdownView(resetsAt: window.resetsAt)
        }
    }

    private var usedLabel: some View {
        Text(usedDescription(window))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(VigilPalette.inkFaint)
    }
}

/// A vertical, divider-separated stack of LimitMeterRows.
struct LimitMeterStack: View {
    let windows: [UsageWindow]
    var accountName: String? = nil
    var status: SnapshotStatus? = nil
    var fetchedAt: Date? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    Divider().overlay(VigilPalette.ink.opacity(0.08))
                }
                LimitMeterRow(
                    window: window,
                    accountName: accountName,
                    status: status,
                    fetchedAt: fetchedAt
                )
            }
        }
    }
}

struct LimitReservoirBar: View {
    let remaining: Double
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(VigilPalette.canvas.opacity(0.78))
                Capsule()
                    .fill(tint)
                    .frame(
                        width: geometry.size.width
                            * min(max(remaining, 0), 100) / 100
                    )
            }
        }
        .frame(height: 8)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.25),
            value: remaining
        )
        .accessibilityHidden(true)
    }
}

/// Kept as compatibility wrappers for previews and any older call sites.
struct WindowGaugeRow: View {
    let title: String
    let window: UsageWindow
    var prominent = false

    var body: some View {
        LimitWindowView(window: window, compact: !prominent)
    }
}

struct WindowBarRow: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        LimitWindowView(window: window, compact: true)
    }
}

func accessibilityCountdown(_ resetsAt: Date?) -> Text {
    guard let resetsAt else { return Text("No reset reported") }
    if resetsAt <= Date() { return Text("Reset due, awaiting refresh") }
    return Text("Resets \(resetsAt, style: .relative) from now")
}

/// Client-computed countdown: ticks natively with zero network
/// (docs/architecture.md "Client-computed countdowns").
struct ResetCountdownView: View {
    let resetsAt: Date?

    var body: some View {
        let now = Date()
        Group {
            if let resetsAt {
                if resetsAt > now {
                    HStack(spacing: 4) {
                        Text("Resets in")
                        Text(timerInterval: now...resetsAt, countsDown: true)
                            .monospacedDigit()
                    }
                } else {
                    Text("Reset due · awaiting refresh")
                }
            } else {
                Text("No reset reported")
            }
        }
        .font(.caption)
        .foregroundStyle(VigilPalette.inkMuted)
    }
}

enum UsageTint {
    static func color(for utilization: Double) -> Color {
        VigilPalette.limitColor(utilization: utilization)
    }
}

private func usedDescription(_ window: UsageWindow) -> String {
    let percent = "\(Int(window.utilization.rounded()))% used"
    guard let used = window.used, let limit = window.limit else { return percent }
    if !UsagePresentation.exactAmountsMatchUtilization(window) {
        let remaining = window.remaining.map { ", \(usageNumber($0)) remaining" } ?? ""
        return "\(percent) · Provider amounts: \(usageNumber(used)) used, \(usageNumber(limit)) limit\(remaining)"
    }
    let exact = "\(usageNumber(used)) / \(usageNumber(limit)) used"
    guard let remaining = window.remaining else { return "\(percent) · \(exact)" }
    return "\(percent) · \(exact) · \(usageNumber(remaining)) left"
}

private func accessibilityUsedDescription(_ window: UsageWindow) -> String {
    let percent = "\(Int(window.utilization.rounded())) percent used"
    guard let used = window.used, let limit = window.limit else { return percent }
    if !UsagePresentation.exactAmountsMatchUtilization(window) {
        let remaining = window.remaining.map { ", \(usageNumber($0)) remaining" } ?? ""
        return "\(percent), provider reports \(usageNumber(used)) used, \(usageNumber(limit)) limit\(remaining)"
    }
    let exact = "\(usageNumber(used)) of \(usageNumber(limit)) used"
    guard let remaining = window.remaining else { return "\(percent), \(exact)" }
    return "\(percent), \(exact), \(usageNumber(remaining)) left"
}

private func usageNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

/// Scalar spend and balance values remain amounts because inventing a
/// percentage without a provider-supplied limit would misstate the account.
struct UsageMetricRow: View {
    let metric: UsageMetric

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MetricFormat.symbol(for: metric.kind))
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(metricTint)
                .background(metricTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                Text(formattedValue)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(VigilPalette.ink)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(12)
        .vigilInsetSurface(cornerRadius: VigilRadius.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.label))
        .accessibilityValue(Text(formattedValue))
    }

    private var metricTint: Color {
        switch metric.kind {
        case .balance, .remaining: return VigilPalette.safe
        case .spend: return VigilPalette.caution
        case .limit: return VigilPalette.signal
        }
    }

    private var formattedValue: String {
        MetricFormat.value(metric)
    }
}
