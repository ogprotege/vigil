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
                Text("\(Int(window.utilization.rounded()))% used")
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
                    + "\(Int(window.utilization.rounded())) percent used"
            )
        )
        .accessibilityHint(accessibilityCountdown(window.resetsAt))
    }
}

/// A compact stacked limit bar: name (+ optional account) on top, a full-width
/// reservoir, and reset + used underneath. Reads as a clean scannable list —
/// used by the account cards and the Models view.
struct LimitMeterRow: View {
    let window: UsageWindow
    /// Shown under the title when the same row appears across accounts (Models view).
    var accountName: String? = nil
    /// Snapshot the window came from, so a row never presents preserved
    /// last-good numbers as current. `UsageService` deliberately keeps the last
    /// good windows on authExpired / network / rateLimited / schemaChanged, so
    /// without this a three-day-old value renders with a live-ticking countdown
    /// and no marker at all.
    var status: SnapshotStatus? = nil
    var fetchedAt: Date? = nil

    private var remaining: Double {
        UsagePresentation.remainingPercent(for: window)
    }

    private var isDegraded: Bool {
        guard let status, let fetchedAt else { return false }
        return SnapshotFreshness.isDegraded(status: status, fetchedAt: fetchedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(UsagePresentation.title(for: window))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(1)
                    if let accountName {
                        Text(accountName)
                            .font(.caption2)
                            .foregroundStyle(VigilPalette.inkFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(remaining.rounded()))%")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .foregroundStyle(UsageTint.color(for: window.utilization))
                    Text("left")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }

            LimitReservoirBar(
                remaining: remaining,
                tint: UsageTint.color(for: window.utilization)
            )

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isDegraded, let status, let fetchedAt {
                    // Not current: say so instead of ticking a countdown that
                    // implies the number behind it is live.
                    Label(
                        UsagePresentation.stalenessNote(status: status, fetchedAt: fetchedAt),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(VigilPalette.caution)
                    .lineLimit(1)
                } else {
                    ResetCountdownView(resetsAt: window.resetsAt)
                }
                Spacer()
                Text("\(Int(window.utilization.rounded()))% used")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(VigilPalette.inkFaint)
            }
        }
        .padding(.vertical, 9)
        .opacity(isDegraded ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text((accountName.map { "\($0), " } ?? "") + UsagePresentation.title(for: window))
        )
        .accessibilityValue(
            Text(
                "\(Int(remaining.rounded())) percent left, "
                    + "\(Int(window.utilization.rounded())) percent used"
                    + (isDegraded && status != nil && fetchedAt != nil
                        ? ", \(UsagePresentation.stalenessNote(status: status!, fetchedAt: fetchedAt!))"
                        : "")
            )
        )
        .accessibilityHint(isDegraded ? Text("") : accessibilityCountdown(window.resetsAt))
    }
}

/// A vertical, divider-separated stack of LimitMeterRows.
struct LimitMeterStack: View {
    let windows: [UsageWindow]
    var accountName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    Divider().overlay(VigilPalette.ink.opacity(0.08))
                }
                LimitMeterRow(window: window, accountName: accountName)
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
    guard let resetsAt else { return Text("No reset scheduled") }
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
                Text("No reset scheduled")
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
