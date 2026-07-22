import SwiftUI
import VigilKit

/// Phone-native account setup. Paste a provider key or use the browser-backed
/// Claude and Codex sign-in flows to mint Vigil-owned renewing credentials.
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pending: PendingAction?
    @State private var isLinking = false
    @State private var linkingTask: Task<Void, Never>?

    private enum PendingAction {
        case failed(String)
        case confirmUnverified(LinkSource, String)
        case confirmReplace(LinkSource, [String])
    }

    private enum LinkSource {
        case credentials(Credentials)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VigilScreenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: VigilSpacing.large) {
                        intro
                        directProviderSection
                        renewingSignInSection
                        privacyNote
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(VigilSpacing.medium)
                    .padding(.bottom, VigilSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(VigilPalette.canvas.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            Text(introDetail)
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var introDetail: String {
        "Paste a provider key, or sign in with Claude or Codex on this phone. No computer required."
    }

    private var renewingSignInSection: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(
                "Mint a renewing token",
                eyebrow: "Optional",
                detail: "OAuth"
            )
            Text("Only needed if you want Vigil to own a refreshable sign-in. Pasting a provider key is enough to watch limits.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            claudeSignInCard
            codexSignInCard
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
                        VigilStatusPill(text: "Renewing", color: VigilPalette.inkMuted)
                    }
                    Text("Approve access in your browser and paste the code back. Vigil refreshes its own token while the provider permits it.")
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
            .buttonStyle(.bordered)
            .tint(VigilPalette.ink)
            .foregroundStyle(VigilPalette.ink)
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
                        VigilStatusPill(text: "Renewing", color: VigilPalette.inkMuted)
                    }
                    Text("Open ChatGPT's sign-in and enter the code Vigil shows you. Vigil refreshes its own token while the provider permits it.")
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
            .buttonStyle(.bordered)
            .tint(VigilPalette.ink)
            .foregroundStyle(VigilPalette.ink)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var directProviderSection: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            VigilSectionHeading(
                "Paste a provider key",
                eyebrow: "Local",
                detail: "\(ProviderRegistry.all.count) available"
            )
            Text("The simplest path: paste an API key or token. Claude and Codex tokens pasted here do not auto-renew, so use browser sign-in when you want renewing credentials.")
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
                Button("Cancel") {
                    linkingTask?.cancel()
                    linkingTask = nil
                    isLinking = false
                }
                .buttonStyle(.bordered)
                .tint(VigilPalette.inkMuted)
                .padding(.top, 4)
            }
            .padding(24)
            .vigilCard(padding: VigilSpacing.large)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verifying account with the provider")
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
        linkingTask?.cancel()
        linkingTask = Task {
            isLinking = true
            defer {
                isLinking = false
                linkingTask = nil
            }
            do {
                try Task.checkCancellation()
                switch source {
                case .credentials(let credentials):
                    try await model.addAccount(
                        credentials: credentials,
                        allowUnverified: allowUnverified,
                        allowReplace: allowReplace
                    )
                }
                guard !Task.isCancelled else { return }
                dismiss()
            } catch is CancellationError {
                // User cancelled the verify overlay.
            } catch AppModel.LinkError.verifyFailed(.network) {
                guard !Task.isCancelled else { return }
                pending = .confirmUnverified(
                    source,
                    "Network problem while verifying. Save and verify later?"
                )
            } catch AppModel.LinkError.verificationDeferred(_) {
                guard !Task.isCancelled else { return }
                pending = .confirmUnverified(
                    source,
                    "Vigil's polling safety cooldown deferred this check. Save now and verify on the next allowed refresh?"
                )
            } catch AppModel.LinkError.wouldReplace(let labels) {
                guard !Task.isCancelled else { return }
                pending = .confirmReplace(source, labels)
            } catch {
                guard !Task.isCancelled else { return }
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
