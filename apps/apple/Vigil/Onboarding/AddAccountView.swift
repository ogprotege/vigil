import SwiftUI
import VigilKit

/// Provider-first account setup. The safest and easiest path stays first:
/// discover credentials on the computer, then hand them to Vigil with a
/// short-lived QR or paste code. Direct provider entry remains available.
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showScanner = false
    @State private var pending: PendingAction?
    @State private var isLinking = false

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
            ZStack {
                VigilScreenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: VigilSpacing.large) {
                        intro
                        claudeSignInCard
                        codexSignInCard
                        directProviderSection
                        computerPairingCard
                        privacyNote
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(VigilSpacing.medium)
                    .padding(.bottom, VigilSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isLinking {
                    linkingOverlay
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
            .alert(
                alertTitle,
                isPresented: .init(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                )
            ) {
                switch pending {
                case .confirmUnverified(let source, _):
                    Button("Save anyway") {
                        run(source, allowUnverified: true, allowReplace: true)
                    }
                    Button("Cancel", role: .cancel) {}
                case .confirmReplace(let source, _):
                    Button("Replace") {
                        run(source, allowUnverified: false, allowReplace: true)
                    }
                    Button("Cancel", role: .cancel) {}
                default:
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(alertMessage)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "Connections")
            Text("Bring an account under watch.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Set up right here on your phone — sign in to Claude or paste a provider key. No computer needed.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var claudeSignInCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(alignment: .top, spacing: 12) {
                VigilProviderMark(providerId: "claude", displayName: "Claude", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sign in with Claude")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VigilPalette.ink)
                        Spacer()
                        VigilStatusPill(text: "On phone", color: VigilPalette.signal)
                    }
                    Text("Approve access in your browser and paste the code back — Vigil gets its own token that renews itself.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
            NavigationLink {
                ClaudeSignInView { credentials in
                    attempt(.credentials(credentials))
                }
            } label: {
                Label("Sign in with Claude", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var codexSignInCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(alignment: .top, spacing: 12) {
                VigilProviderMark(providerId: "codex", displayName: "ChatGPT / Codex", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sign in with Codex")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VigilPalette.ink)
                        Spacer()
                        VigilStatusPill(text: "On phone", color: VigilPalette.signal)
                    }
                    Text("Open ChatGPT's sign-in, enter the code Vigil shows you, and you're done — Vigil keeps its own token that renews itself.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
            NavigationLink {
                CodexSignInView { credentials in
                    attempt(.credentials(credentials))
                }
            } label: {
                Label("Sign in with Codex", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var computerPairingCard: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(VigilPalette.signal)
                    .frame(width: 48, height: 48)
                    .background(
                        VigilPalette.signal.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Already signed in on a computer?")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VigilPalette.ink)
                        Spacer()
                        VigilStatusPill(text: "Optional", color: VigilPalette.inkMuted)
                    }
                    Text("Prefer to reuse the sign-ins already on your computer? Hand your Claude Code or Codex session to your phone with a QR.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }

            setupStep(number: "1", title: "Run this on your computer") {
                CopyableCommandView(command: pairingCommand)
            }

            setupStep(number: "2", title: "Bring the link code into Vigil") {
                HStack(spacing: 10) {
                    #if os(iOS)
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VigilPalette.signal)
                    .foregroundStyle(VigilPalette.canvas)
                    #endif

                    NavigationLink {
                        PasteCodeView { payload in
                            attempt(.payload(payload))
                        }
                    } label: {
                        Label("Paste code", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(VigilPalette.ink)
                }
            }

            Text(pairingSafetyNote)
                .font(.caption2)
                .foregroundStyle(VigilPalette.inkFaint)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var pairingCommand: String {
        #if os(macOS)
        "npx vigil-link --json --yes"
        #else
        "npx vigil-link"
        #endif
    }

    private var pairingSafetyNote: String {
        #if os(macOS)
        "Paste mode prints credential-bearing lines because --yes confirms that choice. Paste them into Vigil, then clear your terminal scrollback. The link expires after 10 minutes."
        #else
        "The codes rotate on screen until you confirm capture, then the terminal clears. Scanning keeps credentials out of the clipboard. The link expires after 10 minutes."
        #endif
    }

    private var directProviderSection: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(
                "Add a provider directly",
                eyebrow: "On phone",
                detail: "\(ProviderRegistry.all.count) available"
            )
            Text("Enter any provider's key or token directly. Vigil asks only for the fields that provider needs. (Claude is easiest via Sign in with Claude above.)")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(ProviderRegistry.all, id: \.id) { spec in
                    NavigationLink {
                        ManualEntryView(providerId: spec.id) { credentials in
                            attempt(.credentials(credentials))
                        }
                    } label: {
                        ProviderSetupRow(spec: spec)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(VigilPalette.signal)
            Text("Credentials stay in this device's Keychain. Vigil sends usage requests directly to the provider. There is no Vigil server.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilInsetSurface()
    }

    private var linkingOverlay: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(VigilPalette.signal)
                Text("Verifying with the provider…")
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                Text("Nothing is saved until this check finishes.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
            .padding(24)
            .vigilCard(padding: VigilSpacing.large)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verifying account with the provider")
    }

    private func setupStep<Content: View>(
        number: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(VigilPalette.canvas)
                .frame(width: 24, height: 24)
                .background(VigilPalette.signal, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        case .confirmUnverified(_, let message): return message
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
                    try await model.addAccounts(
                        from: payload,
                        allowUnverified: allowUnverified,
                        allowReplace: allowReplace
                    )
                case .credentials(let credentials):
                    try await model.addAccount(
                        credentials: credentials,
                        allowUnverified: allowUnverified,
                        allowReplace: allowReplace
                    )
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

private struct ProviderSetupRow: View {
    let spec: ProviderSpec

    var body: some View {
        HStack(spacing: 12) {
            VigilProviderMark(
                providerId: spec.id,
                displayName: spec.displayName,
                size: 40
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(spec.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VigilPalette.ink)
                        .lineLimit(1)
                    if spec.experimental {
                        ExperimentalBadge()
                    }
                }
                Text(ProviderPresentation.setupLabel(for: spec))
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(VigilPalette.inkFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .vigilInsetSurface()
        .contentShape(Rectangle())
    }
}

struct CopyableCommandView: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
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
                Label(
                    copied ? "Copied" : "Copy",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.caption.weight(.semibold))
                .frame(minWidth: 68, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(copied ? VigilPalette.safe : VigilPalette.inkMuted)
            .accessibilityLabel(copied ? "Copied command" : "Copy command")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .vigilInsetSurface(cornerRadius: VigilRadius.small)
    }
}
