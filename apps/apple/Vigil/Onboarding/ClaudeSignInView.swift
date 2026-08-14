import SwiftUI
import VigilKit

/// On-phone "Sign in with Claude" — no computer required. Opens Claude's OAuth
/// consent in the browser, the user pastes back the code Claude shows, and the
/// app exchanges it for a Vigil-owned (mintable, refreshable) token pair. This
/// implements the browser mint described by ADR-0005, using Claude's
/// out-of-band redirect instead of a desktop loopback server.
struct ClaudeSignInView: View {
    let onComplete: (Credentials) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var pkce: ClaudeAuth.PKCE?
    @State private var pastedCode = ""
    @State private var didOpen = false
    @State private var exchangeAttempt = SignInAttempt()
    @State private var errorMessage: String?

    private var oauth: OAuthEndpoint { ProviderRegistry.claude.oauth! }
    private var redirectURI: String { oauth.manualRedirectUri }
    private var canLink: Bool {
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
                    stepOne
                    stepTwo
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(VigilPalette.caution)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(VigilSpacing.medium)
            }
        }
        .navigationTitle("Sign in with Claude")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay { if exchangeAttempt.isRunning { exchangingOverlay } }
        .onAppear { _ = ensurePKCE() }
        .onDisappear { exchangeAttempt.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "Claude")
            Text("Sign in on your phone.")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("No computer needed. You approve access in your browser, then paste the short code Claude gives you.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Text("1  Approve access")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
            Text("Open Claude's sign-in, approve Vigil, and Claude will show you a code to copy.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            Button {
                openAuthorization()
            } label: {
                Label(didOpen ? "Reopen Claude sign-in" : "Open Claude sign-in", systemImage: "safari")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(VigilPalette.signal)
            .foregroundStyle(VigilPalette.canvas)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: VigilSpacing.medium) {
            Text("2  Paste the code")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VigilPalette.ink)
            Text("Paste the code Claude showed you. Vigil finishes signing in with its own token that renews automatically.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            TextField("Paste code from Claude", text: $pastedCode)
                .textFieldStyle(.plain)
                .padding(12)
                .background(VigilPalette.canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif
            Button("Finish signing in") { link() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .buttonStyle(.borderedProminent)
                .tint(VigilPalette.signal)
                .foregroundStyle(VigilPalette.canvas)
                .disabled(!canLink)
        }
        .vigilCard(padding: VigilSpacing.large)
    }

    private var exchangingOverlay: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(VigilPalette.signal)
                Text("Finishing sign-in…")
                    .font(.headline)
                    .foregroundStyle(VigilPalette.ink)
                Button("Cancel") {
                    exchangeAttempt.cancel()
                }
                .buttonStyle(.bordered)
                .tint(VigilPalette.inkMuted)
                .padding(.top, 4)
            }
            .padding(24)
            .vigilCard(padding: VigilSpacing.large)
        }
    }

    private func openAuthorization() {
        errorMessage = nil
        guard let pkce = ensurePKCE() else { return }
        let url = ClaudeAuth.authorizeURL(
            oauth: oauth,
            redirectURI: redirectURI,
            challenge: pkce.challenge,
            state: pkce.state
        )
        didOpen = true
        openURL(url)
    }

    @discardableResult
    private func ensurePKCE() -> ClaudeAuth.PKCE? {
        if let pkce { return pkce }
        do {
            let created = try ClaudeAuth.generatePKCE()
            pkce = created
            return created
        } catch {
            errorMessage = "This device couldn't create a secure sign-in challenge. Try again."
            return nil
        }
    }

    private func resetPKCE(message: String) {
        pkce = nil
        pastedCode = ""
        didOpen = false
        errorMessage = message
        _ = ensurePKCE()
    }

    private func link() {
        errorMessage = nil
        guard let pkce,
              let code = ClaudeAuth.parsePastedCode(pastedCode, expectedState: pkce.state)
        else {
            errorMessage = "That code didn't look right. Copy the whole code Claude showed you and try again."
            return
        }
        exchangeAttempt.start { isCurrent in
            let request = ClaudeAuth.exchangeRequest(
                oauth: oauth,
                code: code,
                redirectURI: redirectURI,
                verifier: pkce.verifier,
                state: pkce.state
            )
            do {
                let (data, response) = try await ProviderUsageSession.shared.data(for: request)
                // A cancelled or superseded exchange publishes nothing: not
                // credentials, not an error, not a fresh PKCE.
                guard isCurrent(), !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let credentials = ClaudeAuth.credentials(fromExchange: data)
                else {
                    // A fresh PKCE for the next attempt: a used/expired code can't be retried.
                    resetPKCE(
                        message: "Claude didn't accept that code — it may have expired. Tap 'Reopen Claude sign-in' to start over."
                    )
                    return
                }
                onComplete(credentials)
                dismiss()
            } catch is CancellationError {
                // User cancelled or the view went away.
            } catch {
                guard isCurrent(), !Task.isCancelled else { return }
                errorMessage = "Couldn't reach Claude to finish signing in. Check your connection and try again."
            }
        }
    }
}
