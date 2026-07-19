import SwiftUI
import VigilKit

/// The session window: a prominent circular gauge + ticking reset countdown.
struct WindowGaugeRow: View {
    let title: String
    let window: UsageWindow
    var prominent = false

    var body: some View {
        HStack(spacing: 16) {
            Gauge(value: min(max(window.utilization, 0), 100), in: 0...100) {
                Text(title)
            } currentValueLabel: {
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    // Dynamic Type can outgrow the fixed ring — scale, don't clip.
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(UsageTint.color(for: window.utilization))
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ResetCountdownView(resetsAt: window.resetsAt)
            }
            Spacer()
        }
        // One VoiceOver element: "Session, 27 percent used, resets in ...".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(Int(window.utilization.rounded())) percent used"))
        .accessibilityValue(accessibilityCountdown(window.resetsAt))
    }
}

func accessibilityCountdown(_ resetsAt: Date?) -> Text {
    guard let resetsAt else { return Text("no reset scheduled") }
    if resetsAt <= Date() { return Text("reset due, awaiting refresh") }
    return Text("resets \(resetsAt, style: .relative) from now")
}

/// Weekly / secondary windows: a linear bar + countdown.
struct WindowBarRow: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Gauge(value: min(max(window.utilization, 0), 100), in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(UsageTint.color(for: window.utilization))
            ResetCountdownView(resetsAt: window.resetsAt)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(Int(window.utilization.rounded())) percent used"))
        .accessibilityValue(accessibilityCountdown(window.resetsAt))
    }
}

/// Client-computed countdown: ticks natively with zero network
/// (docs/architecture.md "Client-computed countdowns").
struct ResetCountdownView: View {
    let resetsAt: Date?

    var body: some View {
        // One clock read: a second `.now` between the check and the range
        // construction could invert the ClosedRange at the boundary and trap.
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
                    Text("Reset due — awaiting refresh")
                }
            } else {
                Text("No reset scheduled")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

enum UsageTint {
    static func color(for utilization: Double) -> Color {
        if utilization >= 95 { return .red }
        if utilization >= 80 { return .orange }
        return .green
    }
}

/// Scalar spend and balance values for providers that do not expose
/// reset-based percentage windows. These remain amounts because inventing a
/// percentage without a provider-supplied limit would misstate the account.
struct UsageMetricRow: View {
    let metric: UsageMetric

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MetricFormat.symbol(for: metric.kind))
                .frame(width: 24)
                .foregroundStyle(MetricFormat.tint(for: metric.kind))
                .accessibilityHidden(true)
            Text(metric.label)
                .font(.subheadline)
            Spacer()
            Text(formattedValue)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.label))
        .accessibilityValue(Text(formattedValue))
    }

    private var formattedValue: String {
        MetricFormat.value(metric)
    }
}
