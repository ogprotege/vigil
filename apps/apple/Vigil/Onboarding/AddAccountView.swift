import SwiftUI
import VigilKit

/// Add Account: three paths, easiest first — scan from the computer, paste
/// the code, manual token entry (docs/local-next-steps.md Phase 3).
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showScanner = false
    @State private var pending: PendingAction?
    @State private var isLinking = false

    /// One decoded/typed credential set moving through the confirm ladder:
    /// replace confirmation, then save-anyway on network verify failure.
    enum PendingAction {
        case failed(String)
        case confirmUnverified(LinkSource, String)
        case confirmReplace(LinkSource, [String])
    }

    enum LinkSource {
        case payload(LinkPayload)
        case credentials(Credentials)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    #if os(iOS)
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan from your computer", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                    #endif
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On your computer, run:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        CopyableCommandView(command: "npx vigil-link")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("From your computer")
                } footer: {
                    Text("vigil-link finds supported CLI sign-ins and opt-in API keys, then shows QR codes to scan. It never stores credentials or usage values.")
                }

                Section("Paste a link code") {
                    NavigationLink {
                        PasteCodeView { payload in
                            attempt(.payload(payload))
                        }
                    } label: {
                        Label("Paste code", systemImage: "doc.on.clipboard")
                    }
                }

                Section("Manual") {
                    NavigationLink {
                        ManualEntryView { credentials in
                            attempt(.credentials(credentials))
                        }
                    } label: {
                        Label("Enter tokens manually", systemImage: "key")
                    }
                }
            }
            .navigationTitle("Add Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isLinking {
                    ProgressView("Verifying…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showScanner) {
                ScanView { payload in
                    showScanner = false
                    attempt(.payload(payload))
                }
            }
            #endif
            .alert(alertTitle, isPresented: .init(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )) {
                switch pending {
                case .confirmUnverified(let source, _):
                    Button("Save anyway") { run(source, allowUnverified: true, allowReplace: true) }
                    Button("Cancel", role: .cancel) {}
                case .confirmReplace(let source, _):
                    Button("Replace") { run(source, allowUnverified: false, allowReplace: true) }
                    Button("Cancel", role: .cancel) {}
                default:
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(alertMessage)
            }
        }
    }

    private var alertTitle: String {
        switch pending {
        case .confirmUnverified: return "Couldn't verify"
        case .confirmReplace: return "Replace account?"
        default: return "Couldn't link"
        }
    }

    private var alertMessage: String {
        switch pending {
        case .failed(let message): return message
        case .confirmUnverified(_, let message):
            return message
        case .confirmReplace(_, let labels):
            return "This replaces the already-linked \(labels.joined(separator: ", "))."
        case nil: return ""
        }
    }

    private func attempt(_ source: LinkSource) {
        run(source, allowUnverified: false, allowReplace: false)
    }

    private func run(_ source: LinkSource, allowUnverified: Bool, allowReplace: Bool) {
        Task {
            isLinking = true
            defer { isLinking = false }
            do {
                switch source {
                case .payload(let payload):
                    try await model.addAccounts(from: payload, allowUnverified: allowUnverified, allowReplace: allowReplace)
                case .credentials(let credentials):
                    try await model.addAccount(credentials: credentials, allowUnverified: allowUnverified, allowReplace: allowReplace)
                }
                dismiss()
            } catch AppModel.LinkError.verifyFailed(.network) {
                pending = .confirmUnverified(
                    source,
                    "Network problem while verifying. Save and verify later?"
                )
            } catch AppModel.LinkError.verificationDeferred(_) {
                pending = .confirmUnverified(
                    source,
                    "Vigil's polling safety cooldown deferred this check. Save now and verify on the next allowed refresh?"
                )
            } catch AppModel.LinkError.wouldReplace(let labels) {
                pending = .confirmReplace(source, labels)
            } catch {
                pending = .failed(error.localizedDescription)
            }
        }
    }
}

struct CopyableCommandView: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                #if os(iOS)
                UIPasteboard.general.string = command
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                #endif
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    // 44pt minimum touch target (Apple HIG).
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
