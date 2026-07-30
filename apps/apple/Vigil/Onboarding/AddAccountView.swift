import SwiftUI
import VigilKit

enum SetupRoute: String, Hashable, Identifiable {
    case claude
    case codex
    case other

    var id: String { rawValue }
}

/// Guided sign-in is the default. Manual credentials remain one disclosed path
/// for providers that do not offer a phone-native authorization flow.
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var path: [SetupRoute]
    @State private var pending: PendingAction?
    @State private var isLinking = false
    @State private var linkingTask: Task<Void, Never>?
    @State private var activeLinkAttemptID: UUID?
    private let relinkTarget: AccountRef?

    init(initialRoute: SetupRoute? = nil, relinkTarget: AccountRef? = nil) {
        self.relinkTarget = relinkTarget
        let route = initialRoute ?? relinkTarget.map {
            Self.relinkRoute(forProviderId: $0.providerId)
        }
        _path = State(initialValue: route.map { [$0] } ?? [])
    }

    private enum PendingAction {
        case failed(String)
        case confirmUnverified(LinkSource, String)
        case confirmReplace(LinkSource, [String])
    }

    enum LinkFailureResolution: Equatable {
        case offerUnverifiedSave(String)
        case offerReplace([String])
        case fail(String)
    }

    /// Maps a link failure to the alert the user should see. Every state that
    /// can be verified later — network trouble, a provider cooldown, or a
    /// provider response this Vigil build cannot read — offers "Save anyway";
    /// a credential the provider rejected never does. Without the
    /// schemaChanged path here, removing a drifted account strands the user:
    /// re-adding it re-verifies against the same drifted response and fails.
    static func linkFailureResolution(for error: any Error) -> LinkFailureResolution {
        switch error {
        case AppModel.LinkError.verifyFailed(.network):
            return .offerUnverifiedSave("Network problem while verifying. Save and verify later?")
        case AppModel.LinkError.verifyFailed(.schemaChanged):
            return .offerUnverifiedSave(
                "The provider responded, but this version of Vigil couldn't read its usage fields. Save anyway to keep the account linked, then update Vigil."
            )
        case AppModel.LinkError.verificationDeferred(_):
            return .offerUnverifiedSave("A provider cooldown deferred verification. Save now and verify at the next allowed check?")
        case AppModel.LinkError.wouldReplace(let labels):
            return .offerReplace(labels)
        default:
            return .fail(error.localizedDescription)
        }
    }

    private enum LinkSource {
        case credentials(Credentials)
    }

    var body: some View {
        NavigationStack(path: $path) {
            setupOverview
                .navigationDestination(for: SetupRoute.self) { route in
                    destination(for: route)
                        .toolbar { closeToolbar }
                }
                .toolbar { closeToolbar }
        }
        .toolbarBackground(VigilPalette.canvas.opacity(0.97), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay { if isLinking { linkingOverlay } }
        .alert(
            alertTitle,
            isPresented: .init(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )
        ) {
            alertActions
        } message: {
            Text(alertMessage)
        }
        .onDisappear { cancelLinking() }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                cancelLinking()
                dismiss()
            }
            .accessibilityIdentifier("vigil.addAccount.close")
        }
    }

    private var setupOverview: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Connect an account")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(VigilPalette.ink)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("Choose the provider you want Vigil to watch.")
                                .font(.subheadline)
                                .foregroundStyle(VigilPalette.inkMuted)
                        }
                    }

                    VStack(spacing: 12) {
                        NavigationLink(value: SetupRoute.claude) {
                            SetupChoiceRow(
                                symbol: "sparkles",
                                title: "Connect Claude",
                                detail: "Sign in through Claude and keep the connection renewable.",
                                tone: .primary
                            )
                        }
                        NavigationLink(value: SetupRoute.codex) {
                            SetupChoiceRow(
                                symbol: "terminal",
                                title: "Connect ChatGPT / Codex",
                                detail: "Use OpenAI's device authorization on this iPhone."
                            )
                        }
                        NavigationLink(value: SetupRoute.other) {
                            SetupChoiceRow(
                                symbol: "key.horizontal",
                                title: "Other provider",
                                detail: "Choose a provider and enter its API key or token.",
                                tone: .quiet
                            )
                        }
                    }
                    .buttonStyle(.plain)

                    privacyNote
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Add account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func destination(for route: SetupRoute) -> some View {
        switch route {
        case .claude:
            ClaudeSignInView { attempt(.credentials($0)) }
        case .codex:
            CodexSignInView { attempt(.credentials($0)) }
        case .other:
            if let relinkTarget {
                ManualEntryView(
                    providerId: relinkTarget.providerId,
                    submitTitle: "Verify and re-link account",
                    locksProvider: true
                ) { attempt(.credentials($0)) }
            } else {
                ProviderCatalogView { attempt(.credentials($0)) }
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "Credentials stay in this iPhone's Keychain. Vigil contacts providers directly.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(VigilPalette.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vigilInsetSurface()
        .accessibilityElement(children: .combine)
    }

    private var linkingOverlay: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(VigilPalette.signal)
                Text("Checking with the provider")
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                Text("Nothing is saved until verification finishes.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                    .multilineTextAlignment(.center)
                Button("Cancel") {
                    cancelLinking()
                }
                .buttonStyle(.bordered)
                .tint(VigilPalette.inkMuted)
            }
            .padding(24)
            .vigilCard(padding: VigilSpacing.large)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verifying account with the provider")
    }

    @ViewBuilder
    private var alertActions: some View {
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
        pending = nil
        let attemptID = UUID()
        activeLinkAttemptID = attemptID
        linkingTask = Task {
            isLinking = true
            defer {
                // A canceled attempt may unwind after the user has already
                // started another one. It must not clear the newer overlay or
                // task handle.
                if activeLinkAttemptID == attemptID {
                    activeLinkAttemptID = nil
                    isLinking = false
                    linkingTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard activeLinkAttemptID == attemptID else { return }
                switch source {
                case .credentials(let credentials):
                    if let relinkTarget {
                        try await model.replaceCredentials(
                            for: relinkTarget,
                            with: credentials,
                            allowUnverified: allowUnverified
                        )
                    } else {
                        try await model.addAccount(
                            credentials: credentials,
                            allowUnverified: allowUnverified,
                            allowReplace: allowReplace
                        )
                    }
                }
                guard !Task.isCancelled, activeLinkAttemptID == attemptID else { return }
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, activeLinkAttemptID == attemptID else { return }
                switch Self.linkFailureResolution(for: error) {
                case .offerUnverifiedSave(let message):
                    pending = .confirmUnverified(source, message)
                case .offerReplace(let labels):
                    pending = .confirmReplace(source, labels)
                case .fail(let message):
                    pending = .failed(message)
                }
            }
        }
    }

    /// Invalidate the attempt identity before canceling its Task. URLSession
    /// and provider bookkeeping can unwind asynchronously, but every completion
    /// path will now refuse to present an alert or dismiss this view later.
    private func cancelLinking() {
        activeLinkAttemptID = nil
        let task = linkingTask
        linkingTask = nil
        isLinking = false
        pending = nil
        task?.cancel()
    }

    static func relinkRoute(forProviderId providerId: String) -> SetupRoute {
        switch providerId {
        case "claude": return .claude
        case "codex": return .codex
        default: return .other
        }
    }
}
