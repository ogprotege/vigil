import SwiftUI
import VigilKit

/// Vigil's "night watch" visual language. The app is intentionally dark:
/// it is a glanceable instrument panel, and the restrained palette keeps the
/// quota signal louder than the chrome around it.
enum VigilPalette {
    static let canvas = Color(red: 0.090, green: 0.063, blue: 0.153)
    static let canvasLift = Color(red: 0.157, green: 0.110, blue: 0.255)
    static let surface = Color(red: 0.145, green: 0.106, blue: 0.231)
    static let surfaceRaised = Color(red: 0.196, green: 0.149, blue: 0.302)
    static let surfaceInset = Color(red: 0.075, green: 0.051, blue: 0.133)
    static let border = Color(red: 0.302, green: 0.255, blue: 0.404)
    static let borderStrong = Color(red: 0.420, green: 0.369, blue: 0.522)

    static let ink = Color(red: 0.961, green: 0.953, blue: 0.980)
    static let inkMuted = Color(red: 0.663, green: 0.631, blue: 0.722)
    static let inkFaint = Color(red: 0.590, green: 0.558, blue: 0.650)

    static let signal = Color(red: 0.392, green: 0.871, blue: 0.714)
    static let safe = signal
    static let caution = Color(red: 0.945, green: 0.788, blue: 0.376)
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
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [VigilPalette.signal.opacity(0.13), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
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
