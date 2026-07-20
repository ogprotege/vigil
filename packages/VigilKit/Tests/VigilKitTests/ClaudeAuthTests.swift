import XCTest
import CryptoKit
@testable import VigilKit

final class ClaudeAuthTests: XCTestCase {
    private let oauth = OAuthEndpoint(
        authorizeUrl: URL(string: "https://claude.ai/oauth/authorize")!,
        tokenUrl: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientId: "test-client",
        scopes: ["user:profile", "user:inference"],
        manualRedirectUri: "https://console.anthropic.com/oauth/code/callback"
    )

    func testPKCEDerivesChallengeFromVerifierAsBase64URLSHA256() {
        let bytes = Data(repeating: 0xAB, count: 32)
        let pkce = ClaudeAuth.generatePKCE(randomBytes: bytes)
        // Verifier is base64url(bytes), no padding.
        XCTAssertFalse(pkce.verifier.contains("="))
        XCTAssertFalse(pkce.verifier.contains("+"))
        XCTAssertFalse(pkce.verifier.contains("/"))
        // Challenge is base64url(SHA256(verifier)).
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.challenge, expected)
        // State is the verifier itself (ADR-0005).
        XCTAssertEqual(pkce.state, pkce.verifier)
    }

    func testAuthorizeURLCarriesEveryRequiredParam() {
        let url = ClaudeAuth.authorizeURL(
            oauth: oauth,
            redirectURI: oauth.manualRedirectUri,
            challenge: "CHAL",
            state: "STATE"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(value("code"), "true")
        XCTAssertEqual(value("client_id"), "test-client")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("redirect_uri"), "https://console.anthropic.com/oauth/code/callback")
        XCTAssertEqual(value("scope"), "user:profile user:inference")
        XCTAssertEqual(value("code_challenge"), "CHAL")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "STATE")
    }

    func testParsePastedCodeAcceptsBareCodeFullURLAndHashForm() {
        // Bare code — state defaults to the expected one.
        XCTAssertEqual(ClaudeAuth.parsePastedCode("abc123", expectedState: "S"), "abc123")
        // code#state.
        XCTAssertEqual(ClaudeAuth.parsePastedCode("abc123#S", expectedState: "S"), "abc123")
        // Full callback URL (e.g. copied from a connection-error page).
        XCTAssertEqual(
            ClaudeAuth.parsePastedCode("http://localhost:54545/callback?code=abc123&state=S", expectedState: "S"),
            "abc123"
        )
        // code&state= form.
        XCTAssertEqual(ClaudeAuth.parsePastedCode("abc123&state=S", expectedState: "S"), "abc123")
    }

    func testParsePastedCodeRejectsAStateMismatch() {
        XCTAssertNil(ClaudeAuth.parsePastedCode("abc123#WRONG", expectedState: "S"))
        XCTAssertNil(
            ClaudeAuth.parsePastedCode("http://x/callback?code=abc123&state=WRONG", expectedState: "S")
        )
    }

    func testExchangeRequestPostsAuthorizationCodeGrant() throws {
        let request = ClaudeAuth.exchangeRequest(
            oauth: oauth,
            code: "abc123",
            redirectURI: oauth.manualRedirectUri,
            verifier: "VER",
            state: "STATE"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, oauth.tokenUrl)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["grant_type"], "authorization_code")
        XCTAssertEqual(json["code"], "abc123")
        XCTAssertEqual(json["redirect_uri"], oauth.manualRedirectUri)
        XCTAssertEqual(json["client_id"], "test-client")
        XCTAssertEqual(json["code_verifier"], "VER")
        XCTAssertEqual(json["state"], "STATE")
    }

    func testCredentialsFromExchangeAreMintedAndRefreshable() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": "sk-ant-oat01-NEW",
            "refresh_token": "sk-ant-ort01-NEW",
            "expires_in": 3600,
        ])
        let creds = try XCTUnwrap(ClaudeAuth.credentials(fromExchange: body, now: now))
        XCTAssertEqual(creds.providerId, "claude")
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-NEW")
        XCTAssertEqual(creds.refreshToken, "sk-ant-ort01-NEW")
        XCTAssertEqual(creds.expiresAt, now.addingTimeInterval(3600))
        // Marked "mint" so the app WILL refresh it (unlike a pasted token).
        XCTAssertEqual(creds.source, TokenRefresher.mintSource)
        XCTAssertNotNil(TokenRefresher.refreshRequest(spec: ProviderRegistry.claude, credentials: creds))
    }

    func testCredentialsFromExchangeRejectMissingAccessToken() {
        let body = "{}".data(using: .utf8)!
        XCTAssertNil(ClaudeAuth.credentials(fromExchange: body, now: Date()))
    }
}
