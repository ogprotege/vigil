import SwiftUI
import VigilKit

/// OpenRouter's phone-native headless OAuth flow. Vigil creates a fresh S256
/// PKCE challenge, opens OpenRouter's fixed consent page, and exchanges the
/// one-time code the user pastes back. The resulting API key is verified by
/// AddAccountView before it is stored in Keychain.
struct OpenRouterSignInView: View {
    let manualSubmitTitle: String
    let onComplete: (Credentials) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var pkce: OpenRouterAuth.PKCE?
    @State private var pastedCode = ""
    @State private var didOpen = false
    @State private var exchangeAttempt = SignInAttempt()
    @State private var errorMessage: String?

    init(
        manualSubmitTitle: String = "Verify and add account",
        onComplete: @escaping (Credentials) -> Void
    ) {
        self.manualSubmitTitle = manualSubmitTitle
        self.onComplete = onComplete
    }

    private var canFinish: Bool {
        pkce != nil
            && !pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !exchangeAttempt.isRunning
    }

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header
                    OpenRouterCredentialNotice()
                    approvalStep
                    codeStep
                    directSetupFallback
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(VigilPalette.caution)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("vigil.openrouter.error")
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(VigilSpacing.medium)
                .padding(.bottom, VigilSpacing.xLarge)
            }
        }
        .navigationTitle("Connect OpenRouter")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityHidden(exchangeAttempt.isRunning)
        .overlay { if exchangeAttempt.isRunning { exchangingOverlay } }
        .onDisappear { exchangeAttempt.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "OpenRouter")
            Text("Authorize on your phone.")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Approve Vigil in OpenRouter, then paste the one-time code OpenRouter gives you.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var approvalStep: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Text("1  Approve access")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
            Text("Vigil creates a new S256 security challenge before opening OpenRouter's official authorization page.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            Button {
                openAuthorization()
            } label: {
                Label(
                    didOpen ? "Reopen OpenRouter authorization" : "Open OpenRouter authorization",
                    systemImage: "safari"
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)
            .disabled(exchangeAttempt.isRunning)
            .accessibilityIdentifier("vigil.openrouter.openAuthorization")
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Text("2  Paste the one-time code")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
            Text("Copy the code shown by OpenRouter and paste it here. Vigil sends it only to OpenRouter's fixed key-exchange endpoint.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            SecureField("One-time code from OpenRouter", text: $pastedCode)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .padding(12)
                .background(
                    VigilPalette.canvas.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .privacySensitive()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif
                .accessibilityIdentifier("vigil.openrouter.code")
            Button("Finish authorization") { exchangeCode() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .buttonStyle(.borderedProminent)
                .tint(VigilPalette.signal)
                .foregroundStyle(VigilPalette.canvas)
                .disabled(!canFinish)
                .accessibilityIdentifier("vigil.openrouter.finish")
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var directSetupFallback: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Text("Already have an OpenRouter API key?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
            Text("You can enter an existing key directly instead of authorizing a new one.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            NavigationLink {
                ManualEntryView(
                    providerId: "openrouter",
                    submitTitle: manualSubmitTitle,
                    locksProvider: true,
                    onSubmit: onComplete
                )
            } label: {
                Label("Enter an API key instead", systemImage: "key.horizontal")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.bordered)
            .tint(VigilPalette.signal)
            .accessibilityIdentifier("vigil.openrouter.useAPIKey")
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var exchangingOverlay: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(VigilPalette.signal)
                    Text("Finishing OpenRouter authorization…")
                        .font(.headline)
                        .foregroundStyle(VigilPalette.ink)
                    Text("The one-time code and security verifier are being sent to OpenRouter.")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                Button("Cancel") {
                    exchangeAttempt.cancel()
                    resetAuthorization(
                        message: "Authorization was canceled. Open OpenRouter again to get a new one-time code."
                    )
                }
                .buttonStyle(.bordered)
                .tint(VigilPalette.inkMuted)
                .accessibilityIdentifier("vigil.openrouter.cancel")
            }
            .padding(24)
            .vigilCard(padding: VigilSpacing.large)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func openAuthorization() {
        errorMessage = nil
        if pkce == nil {
            do {
                pkce = try OpenRouterAuth.generatePKCE()
            } catch {
                errorMessage = "This device couldn't create a secure authorization challenge. Try again."
                return
            }
        }

        guard let pkce, let url = OpenRouterAuth.authorizeURL(pkce: pkce) else {
            resetAuthorization(
                message: "Vigil couldn't prepare OpenRouter's authorization page. Try again."
            )
            return
        }
        didOpen = true
        openURL(url)
    }

    private func exchangeCode() {
        errorMessage = nil
        guard let pkce,
              let request = OpenRouterAuth.exchangeRequest(
                  code: pastedCode,
                  verifier: pkce.verifier
              )
        else {
            errorMessage = "That one-time code doesn't look valid. Copy the code OpenRouter showed you and try again."
            return
        }

        exchangeAttempt.start { isCurrent in
            guard isCurrent(), !Task.isCancelled else { return }
            do {
                let (data, response) = try await ProviderUsageSession.shared.data(for: request)
                guard isCurrent(), !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let credentials = OpenRouterAuth.credentials(fromExchange: data)
                else {
                    resetAuthorization(
                        message: "OpenRouter didn't accept that code. Open authorization again to get a new one-time code."
                    )
                    return
                }
                pastedCode = ""
                onComplete(credentials)
                dismiss()
            } catch is CancellationError {
                // A dismissed or explicitly canceled attempt publishes nothing.
            } catch {
                guard isCurrent(), !Task.isCancelled else { return }
                resetAuthorization(
                    message: "Vigil couldn't reach OpenRouter. Open authorization again and try a new one-time code."
                )
            }
        }
    }

    private func resetAuthorization(message: String) {
        pkce = nil
        pastedCode = ""
        didOpen = false
        errorMessage = message
    }
}

private struct OpenRouterCredentialNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This authorization creates an API key", systemImage: "exclamationmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(VigilPalette.caution)
            Text("The generated key can authorize model spending on your OpenRouter account. Limit the key in OpenRouter where possible, and revoke it there when you stop using Vigil.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VigilPalette.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vigil.openrouter.spendingNotice")
    }
}
