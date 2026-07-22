import Foundation
import XCTest
@testable import VigilKit

/// Opt-in probes against the REAL provider auth endpoints.
///
/// These are the network-side proof that phone-native sign-in request shapes
/// remain accepted by the providers. They hit the network, so they never run
/// in CI: set VIGIL_LIVE_AUTH=1 to run them.
///
///     VIGIL_LIVE_AUTH=1 swift test --package-path packages/VigilKit \
///       --filter LiveAuthVerificationTests
///
/// They verify the mechanics only. The browser-approval half of both flows
/// needs a human and is covered by the on-device walk in Step 4.
final class LiveAuthVerificationTests: XCTestCase {
    private func requireLiveRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIGIL_LIVE_AUTH"] == "1",
            "set VIGIL_LIVE_AUTH=1 to run live endpoint probes"
        )
    }

    /// The authorize URL must be accepted by Anthropic — a malformed client id,
    /// redirect URI, or PKCE challenge shows up here as a 400.
    func testClaudeAuthorizeURLIsAcceptedLive() async throws {
        try requireLiveRun()
        let oauth = try XCTUnwrap(
            ProviderRegistry.claude.oauth,
            "claude must declare oauth metadata"
        )

        let pkce = ClaudeAuth.generatePKCE()
        let url = ClaudeAuth.authorizeURL(
            oauth: oauth,
            redirectURI: oauth.manualRedirectUri,
            challenge: pkce.challenge,
            state: pkce.state
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)

        XCTAssertLessThan(code, 400, "authorize URL rejected with HTTP \(code): \(url)")
        print("LIVE claude authorize -> HTTP \(code)")
    }

    /// Starting the device-code flow needs no approval, so a real device code
    /// coming back proves the request shape and the parser end to end.
    func testCodexDeviceAuthorizationReturnsARealCodeLive() async throws {
        try requireLiveRun()
        let oauth = try XCTUnwrap(
            ProviderRegistry.codex.oauth,
            "codex must declare oauth metadata"
        )

        let request = try XCTUnwrap(
            CodexAuth.userCodeRequest(oauth: oauth),
            "codex oauth metadata must supply a device-code URL"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        XCTAssertLessThan(code, 400, "device authorization failed with HTTP \(code)")

        let parsed = try XCTUnwrap(
            CodexAuth.parseUserCode(data),
            "live device-authorization body did not parse: "
                + (String(data: data, encoding: .utf8) ?? "<non-utf8>")
        )
        XCTAssertFalse(parsed.userCode.isEmpty)
        XCTAssertFalse(parsed.deviceAuthId.isEmpty)
        XCTAssertGreaterThanOrEqual(parsed.intervalSeconds, CodexAuth.minimumPollInterval)
        print("LIVE codex device code -> \(parsed.userCode) (interval \(parsed.intervalSeconds)s)")
    }
}
