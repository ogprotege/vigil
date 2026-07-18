import SwiftUI
import VigilKit

/// The camera-free path: paste the `vigil1:` line(s) printed by
/// `npx vigil-link --json` (or copied from a failed camera scan).
struct PasteCodeView: View {
    let onDecoded: (LinkPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 140)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Link code")
            } footer: {
                Text("On your computer: `npx vigil-link --json`, then copy the whole `vigil1:` line here. Multi-chunk codes: paste every line.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Button("Link") { decode() }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Paste code")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func decode() {
        let lines = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("vigil") }
        guard !lines.isEmpty else {
            errorMessage = "No vigil1 code found — paste the full line starting with \"vigil1:\"."
            return
        }
        do {
            let payload = try QRDecoder.decodePayload(lines, now: Date())
            onDecoded(payload)
            dismiss()
        } catch QRDecodeError.expired {
            errorMessage = "This code expired (older than 10 minutes). Re-run vigil-link for a fresh one."
        } catch QRDecodeError.incomplete(let have, let want) {
            errorMessage = "Only \(have) of \(want) chunks pasted — copy every vigil1 line."
        } catch QRDecodeError.unsupportedVariant {
            errorMessage = "This code needs a newer Vigil — update the app."
        } catch QRDecodeError.sidMismatch {
            errorMessage = "Those lines are from different link sessions — paste one session's lines only."
        } catch {
            errorMessage = "Couldn't decode that code — copy the exact line from vigil-link."
        }
    }
}
