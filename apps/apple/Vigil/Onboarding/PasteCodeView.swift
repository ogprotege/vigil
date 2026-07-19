import SwiftUI
import VigilKit

/// Camera-free link path for the `vigil1:` line(s) printed by Vigil Link.
struct PasteCodeView: View {
    let onDecoded: (LinkPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    VStack(alignment: .leading, spacing: 6) {
                        VigilEyebrow(text: "Computer pairing")
                        Text("Paste the link code.")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(VigilPalette.ink)
                        Text("On your computer, run `npx vigil-link --json --yes` and copy every line beginning with `vigil1:`.")
                            .font(.callout)
                            .foregroundStyle(VigilPalette.inkMuted)
                    }

                    StatusBannerView(
                        icon: "exclamationmark.shield",
                        tint: VigilPalette.caution,
                        text: "Paste-mode lines contain account credentials. Paste them only into Vigil, then clear your terminal scrollback."
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        VigilSectionHeading("Link code", eyebrow: "Expires after 10 minutes")
                        TextEditor(text: $text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(VigilPalette.ink)
                            .accessibilityLabel("Link code")
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 180)
                            .padding(10)
                            .vigilInsetSurface(cornerRadius: VigilRadius.medium)
                            #if os(iOS)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            #endif

                        if let errorMessage {
                            StatusBannerView(
                                icon: "exclamationmark.triangle",
                                tint: VigilPalette.critical,
                                text: errorMessage
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isStaticText)
                        }
                    }
                    .vigilCard(padding: VigilSpacing.medium)

                    Button("Verify and link") {
                        decode()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .buttonStyle(.borderedProminent)
                    .tint(VigilPalette.signal)
                    .foregroundStyle(VigilPalette.canvas)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Paste code")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    private func decode() {
        let lines = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("vigil") }
        guard !lines.isEmpty else {
            errorMessage = "No vigil1 code found. Paste the full line beginning with “vigil1:”."
            return
        }
        do {
            let payload = try QRDecoder.decodePayload(lines, now: Date())
            onDecoded(payload)
            dismiss()
        } catch QRDecodeError.expired {
            errorMessage = "This code expired. Run Vigil Link again for a fresh code."
        } catch QRDecodeError.incomplete(let have, let want) {
            errorMessage = "Only \(have) of \(want) parts are here. Copy every vigil1 line."
        } catch QRDecodeError.unsupportedVariant {
            errorMessage = "This code needs a newer version of Vigil."
        } catch QRDecodeError.sidMismatch {
            errorMessage = "These lines came from different link sessions. Paste one session only."
        } catch {
            errorMessage = "Vigil could not decode this code. Copy the exact Vigil Link output."
        }
    }
}
