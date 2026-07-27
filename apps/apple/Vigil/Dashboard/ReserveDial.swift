import SwiftUI
import VigilKit

/// Vigil's single glance signature. The ring communicates reserve, not use,
/// and always sits beside written percent, window, reset, and freshness text.
struct ReserveDial: View {
    let remaining: Double
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(remaining, 0), 100) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(VigilPalette.border, style: StrokeStyle(lineWidth: 7))
            Circle()
                .trim(from: 0, to: clamped / 100)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(clamped.rounded()))")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(VigilPalette.ink)
                Text("LEFT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
        .frame(width: 68, height: 68)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: clamped)
        .accessibilityHidden(true)
    }
}

struct SnapshotFreshnessLine: View {
    let snapshot: ProviderSnapshot?
    var nextAllowed: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                freshnessText
            } icon: {
                Image(systemName: freshnessSymbol)
            }

            if let nextAllowed, nextAllowed > Date() {
                Label {
                    Text("Next provider check ")
                        + Text(nextAllowed, style: .relative)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(freshnessTint)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var freshnessText: some View {
        if let snapshot, snapshot.fetchedAt > .distantPast {
            if snapshot.status == .ok,
               SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
                Text("Reset passed, awaiting provider update. Last checked ")
                    + Text(snapshot.fetchedAt, style: .relative)
                    + Text(" ago")
            } else if snapshot.status == .ok {
                Text("Checked ") + Text(snapshot.fetchedAt, style: .relative) + Text(" ago")
            } else {
                Text(UsagePresentation.statusTitle(snapshot.status) + ", last checked ")
                    + Text(snapshot.fetchedAt, style: .relative)
                    + Text(" ago")
            }
        } else {
            Text("No successful check yet")
        }
    }

    private var freshnessSymbol: String {
        guard let snapshot else { return "clock" }
        if snapshot.status != .ok {
            return UsagePresentation.statusSymbol(snapshot.status) ?? "exclamationmark.circle"
        }
        if SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
            return "arrow.clockwise.circle"
        }
        return SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt)
            ? "clock.badge.exclamationmark"
            : "checkmark.circle"
    }

    private var freshnessTint: Color {
        guard let snapshot else { return VigilPalette.inkMuted }
        if snapshot.status == .ok,
           SnapshotFreshness.hasUnconfirmedReset(in: snapshot) {
            return VigilPalette.caution
        }
        if snapshot.status == .ok, SnapshotFreshness.isStale(fetchedAt: snapshot.fetchedAt) {
            return VigilPalette.caution
        }
        return snapshot.status == .ok
            ? VigilPalette.inkMuted
            : VigilPalette.statusColor(snapshot.status)
    }
}
