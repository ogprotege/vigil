import SwiftUI
import VigilKit

/// On-phone "Sign in with Grok Build" via standard OIDC device authorization
/// against auth.x.ai. Twin of GrokAuth in VigilKit: this view runs the browser
/// + polling loop and mints a refreshable credential pair.
struct GrokSignInView: View {
    let onComplete: (Credentials) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .requesting
    @State private var pollInterval: TimeInterval = GrokAuth.minimumPollInterval

    private enum Phase: Equatable {
        case requesting
        case waiting(userCode: String, url: URL?)
        case completing
        case failed(String)
    }

    private var oauth: OAuthEndpoint { ProviderRegistry.grok.oauth! }

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
        .navigationTitle("Sign in with Grok Build")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .preferredColorScheme(.dark)
        .task { await run() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VigilEyebrow(text: "Grok Build")
                ExperimentalBadge()
            }
            Text("Sign in on your phone.")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(VigilPalette.ink)
            Text("Open the xAI sign-in page, approve Grok Build access, and enter the code below. Vigil mints its own renewable session.")
                .font(.subheadline)
                .foregroundStyle(VigilPalette.inkMuted)
        }
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
                Text("Open the sign-in page, approve access, and enter this code when asked.")
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
                Button("Try again") { Task { await run() } }
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

    private func run() async {
        phase = .requesting
        pollInterval = GrokAuth.minimumPollInterval
        guard let request = GrokAuth.userCodeRequest(oauth: oauth) else {
            phase = .failed("Grok Build sign-in isn't configured.")
            return
        }
        do {
            let (data, response) = try await ProviderUsageSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let device = GrokAuth.parseUserCode(data)
            else {
                phase = .failed("Couldn't start Grok Build sign-in. Try again.")
                return
            }
            pollInterval = device.intervalSeconds
            phase = .waiting(userCode: device.userCode, url: device.verificationURL)
            await poll(device: device)
        } catch is CancellationError {
            // View went away.
        } catch {
            phase = .failed("Couldn't reach xAI to start Grok Build sign-in.")
        }
    }

    private func poll(device: GrokAuth.DeviceCode) async {
        let deadline = Date().addingTimeInterval(15 * 60)
        do {
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard let request = GrokAuth.pollRequest(
                    oauth: oauth, deviceCode: device.deviceCode
                ) else { break }
                let (data, response) = try await ProviderUsageSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch GrokAuth.parsePoll(statusCode: status, data: data) {
                case .pending:
                    continue
                case .slowDown(let interval):
                    pollInterval = interval
                    continue
                case .authorized(let credentials):
                    phase = .completing
                    onComplete(credentials)
                    dismiss()
                    return
                case .failed:
                    phase = .failed("Sign-in was denied or the code expired. Tap Try again.")
                    return
                }
            }
            phase = .failed("Sign-in timed out. Tap Try again.")
        } catch is CancellationError {
            // View dismissed.
        } catch {
            phase = .failed("Lost the connection while waiting. Tap Try again.")
        }
    }
}
