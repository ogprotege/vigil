import SwiftUI

enum SetupChoiceTone: Equatable {
    case primary
    case standard
    case quiet

    var tint: Color {
        switch self {
        case .primary: return VigilPalette.signal
        case .standard: return VigilPalette.safe
        case .quiet: return VigilPalette.inkMuted
        }
    }
}

/// A shared setup label for first launch and the Add Account sheet. The label
/// changes axis at accessibility sizes so the title, explanation, and action
/// never fight for one narrow line.
struct SetupChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    var tone: SetupChoiceTone = .standard

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    mark
                    copy
                    actionCue
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    mark
                    copy
                    Spacer(minLength: 8)
                    actionCue
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(
            tone.tint.opacity(tone == .primary ? 0.16 : 0.08),
            in: RoundedRectangle(cornerRadius: VigilRadius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VigilRadius.medium, style: .continuous)
                .stroke(tone.tint.opacity(0.38), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityHint("Opens account setup")
    }

    private var mark: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tone.tint)
            .frame(width: 42, height: 42)
            .background(tone.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VigilPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionCue: some View {
        Label("Continue", systemImage: "chevron.right")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.tint)
            .accessibilityHidden(true)
    }
}
