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
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(UsageTint.color(for: window.utilization))
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ResetCountdownView(resetsAt: window.resetsAt)
            }
            Spacer()
        }
    }
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
