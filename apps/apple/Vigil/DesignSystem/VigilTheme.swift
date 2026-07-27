import SwiftUI
import VigilKit

/// Vigil's quiet instrument palette. Carbon and graphite carry the chrome;
/// frost carries content; violet identifies interaction; mint and amber carry
/// provider truth. Status color never substitutes for a written status.
enum VigilPalette {
    static let canvas = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let canvasLift = Color(red: 0.075, green: 0.086, blue: 0.106)
    static let surface = Color(red: 0.086, green: 0.102, blue: 0.125)
    static let surfaceRaised = Color(red: 0.125, green: 0.145, blue: 0.176)
    static let surfaceInset = Color(red: 0.055, green: 0.067, blue: 0.082)
    static let border = Color(red: 0.180, green: 0.204, blue: 0.239)
    static let borderStrong = Color(red: 0.286, green: 0.318, blue: 0.365)

    static let ink = Color(red: 0.957, green: 0.965, blue: 0.976)
    static let inkMuted = Color(red: 0.667, green: 0.698, blue: 0.745)
    static let inkFaint = Color(red: 0.486, green: 0.522, blue: 0.584)

    static let signal = Color(red: 0.616, green: 0.549, blue: 1.000)
    static let safe = Color(red: 0.396, green: 0.839, blue: 0.706)
    static let caution = Color(red: 0.949, green: 0.737, blue: 0.400)
    static let critical = Color(red: 0.941, green: 0.424, blue: 0.451)

    static func limitColor(utilization: Double) -> Color {
        if utilization >= 95 { return critical }
        if utilization >= 80 { return caution }
        return signal
    }

    static func statusColor(_ status: SnapshotStatus) -> Color {
        switch status {
        case .ok: return safe
        case .rateLimited: return caution
        case .authExpired, .schemaChanged: return critical
        case .network: return inkMuted
        }
    }
}

enum VigilSpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum VigilRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
}

struct VigilScreenBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [VigilPalette.canvas, VigilPalette.canvasLift],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [VigilPalette.signal.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct VigilCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                VigilPalette.surface.opacity(0.96),
                in: RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: VigilRadius.large, style: .continuous)
                    .stroke(VigilPalette.border.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

extension View {
    func vigilCard(padding: CGFloat = VigilSpacing.medium) -> some View {
        modifier(VigilCardModifier(padding: padding))
    }

    func vigilInsetSurface(cornerRadius: CGFloat = VigilRadius.medium) -> some View {
        background(
            VigilPalette.surfaceInset,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(VigilPalette.border.opacity(0.46), lineWidth: 1)
        }
    }
}

struct VigilProviderMark: View {
    let providerId: String
    let displayName: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: ProviderPresentation.symbol(for: providerId))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(VigilPalette.ink)
            .frame(width: size, height: size)
            .background(
                ProviderPresentation.tint(for: providerId).opacity(0.24),
                in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                    .stroke(ProviderPresentation.tint(for: providerId).opacity(0.54), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct VigilEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .tracking(1.15)
            .foregroundStyle(VigilPalette.inkMuted)
    }
}

struct VigilStatusPill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(color.opacity(0.3), lineWidth: 1)
        }
    }
}

struct VigilSectionHeading: View {
    let eyebrow: String?
    let title: String
    var detail: String?

    init(_ title: String, eyebrow: String? = nil, detail: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    VigilEyebrow(text: eyebrow)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
            }
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(VigilPalette.inkMuted)
            }
        }
    }
}
