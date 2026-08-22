import SwiftUI
import VigilKit

/// On-phone "Sign in with ChatGPT / Codex" via OpenAI's device-code flow — no
/// computer, no redirect handling. Vigil requests a one-time code, the user
/// approves it in the browser, and Vigil polls for the tokens and mints its own
/// (refreshable) pair. Twin of CodexAuth in VigilKit, which does the pure
/// request/response work; this view runs the browser + polling loop.
struct CodexSignInView: View {
    let onComplete: (Credentials) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .requesting
    @State private var retryAttempt = SignInAttempt()

    private enum Phase: Equatable {
        case requesting
        case waiting(userCode: String, url: URL?)
        case completing
        case failed(String)
    }

    private var oauth: OAuthEndpoint { ProviderRegistry.codex.oauth! }

    var body: some View {
        ZStack {
            VigilScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VigilSpacing.large) {
                    header
                    content
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(VigilSpacing.medium)
            }
        }
        .navigationTitle("Sign in with Codex")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { startSignIn() }
        .onDisappear { retryAttempt.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            VigilEyebrow(text: "ChatGPT / Codex")
            Text("Sign in on your phone.")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Open the sign-in page, approve Vigil, and enter the code below. No computer needed.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
            deviceAuthNotice
        }
    }

    /// OpenAI gates the device-code flow behind a per-account toggle. If it's
    /// off, the approval page shows "Enable device code authorization for Codex"
    /// — so tell the user to flip it first, once.
    private var deviceAuthNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "One-time setup on your ChatGPT account",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(VigilPalette.caution)
            Text("In ChatGPT → Settings → Security, turn on **Device code authorization** before you continue. Without it, OpenAI's page will refuse the code.")
                .font(.caption)
                .foregroundStyle(VigilPalette.inkMuted)
            Button {
                openURL(URL(string: "https://chatgpt.com/#settings/Security")!)
            } label: {
                Label("Open ChatGPT security settings", systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VigilPalette.signal)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VigilPalette.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .requesting:
            statusCard {
                ProgressView().tint(VigilPalette.signal)
                Text("Starting sign-in…").foregroundStyle(VigilPalette.inkMuted)
            }
        case .waiting(let userCode, let url):
            VStack(alignment: .leading, spacing: VigilSpacing.medium) {
                Text("Your code")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VigilPalette.ink)
                Text(userCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(VigilPalette.signal)
                    .textSelection(.enabled)
                Text("Open the sign-in page, approve Vigil, and enter this code when asked.")
                    .font(.caption)
                    .foregroundStyle(VigilPalette.inkMuted)
                if let url {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open sign-in page", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VigilPalette.signal)
                    .foregroundStyle(VigilPalette.canvas)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(VigilPalette.signal)
                    Text("Waiting for you to approve…")
                        .font(.caption)
                        .foregroundStyle(VigilPalette.inkMuted)
                }
            }
            .vigilCard(padding: VigilSpacing.large)
        case .completing:
            statusCard {
                ProgressView().tint(VigilPalette.signal)
                Text("Finishing sign-in…").foregroundStyle(VigilPalette.inkMuted)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: VigilSpacing.medium) {
                Text(message).font(.callout).foregroundStyle(VigilPalette.caution)
                Button("Try again", action: startSignIn)
                    .buttonStyle(.borderedProminent)
                    .tint(VigilPalette.signal)
                    .foregroundStyle(VigilPalette.canvas)
            }
            .vigilCard(padding: VigilSpacing.large)
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vigilCard(padding: VigilSpacing.large)
    }

    private func startSignIn() {
        retryAttempt.start { isCurrent in
            await run(isCurrent: isCurrent)
        }
    }

    private func run(
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard isCurrent(), !Task.isCancelled else { return }
        phase = .requesting
        guard let request = CodexAuth.userCodeRequest(oauth: oauth) else {
            guard isCurrent(), !Task.isCancelled else { return }
            phase = .failed("Codex sign-in isn't configured.")
            return
        }
        do {
            let (data, response) = try await ProviderUsageSession.shared.data(for: request)
            guard isCurrent(), !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let device = CodexAuth.parseUserCode(data)
            else {
                phase = .failed("Couldn't start Codex sign-in. Try again.")
                return
            }
            phase = .waiting(userCode: device.userCode, url: CodexAuth.verificationURL(oauth: oauth))
            await poll(device: device, isCurrent: isCurrent)
        } catch is CancellationError {
            // View went away — nothing to do.
        } catch {
            guard isCurrent(), !Task.isCancelled else { return }
            phase = .failed("Couldn't reach OpenAI to start Codex sign-in.")
        }
    }

    private func poll(
        device: CodexAuth.DeviceCode,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(15 * 60)
        do {
            while Date() < deadline {
                guard isCurrent(), !Task.isCancelled else { return }
                try await Task.sleep(nanoseconds: UInt64(device.intervalSeconds * 1_000_000_000))
                guard isCurrent(), !Task.isCancelled else { return }
                guard let request = CodexAuth.pollRequest(
                    oauth: oauth, deviceAuthId: device.deviceAuthId, userCode: device.userCode
                ) else { break }
                let (data, response) = try await ProviderUsageSession.shared.data(for: request)
                guard isCurrent(), !Task.isCancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch CodexAuth.parsePoll(statusCode: status, data: data) {
                case .pending:
                    continue
                case .authorized(let code, let verifier):
                    await complete(
                        authorizationCode: code,
                        codeVerifier: verifier,
                        isCurrent: isCurrent
                    )
                    return
                case .failed:
                    guard isCurrent(), !Task.isCancelled else { return }
                    phase = .failed("Sign-in was denied or the code expired. Tap Try again.")
                    return
                }
            }
            guard isCurrent(), !Task.isCancelled else { return }
            phase = .failed("Sign-in timed out. Tap Try again.")
        } catch is CancellationError {
            // View dismissed.
        } catch {
            guard isCurrent(), !Task.isCancelled else { return }
            phase = .failed("Lost the connection while waiting. Tap Try again.")
        }
    }

    private func complete(
        authorizationCode: String,
        codeVerifier: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard isCurrent(), !Task.isCancelled else { return }
        phase = .completing
        let request = CodexAuth.exchangeRequest(
            oauth: oauth, authorizationCode: authorizationCode, codeVerifier: codeVerifier
        )
        do {
            let (data, response) = try await ProviderUsageSession.shared.data(for: request)
            // A dismissed or superseded sign-in must never link an account:
            // the user was told nothing happened.
            guard isCurrent(), !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                phase = .failed("Couldn't finish Codex sign-in (HTTP error). Tap Try again.")
                return
            }
            guard let credentials = CodexAuth.credentials(fromTokenResponse: data) else {
                phase = .failed(
                    "OpenAI's response didn't include your account ID. Enable Device code authorization in ChatGPT → Settings → Security, then tap Try again."
                )
                return
            }
            guard isCurrent(), !Task.isCancelled else { return }
            onComplete(credentials)
            dismiss()
        } catch is CancellationError {
            // View disappeared or a retry superseded this attempt.
        } catch {
            guard isCurrent(), !Task.isCancelled else { return }
            phase = .failed("Couldn't finish Codex sign-in. Tap Try again.")
        }
    }
}
