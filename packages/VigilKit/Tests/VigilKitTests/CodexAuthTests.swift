import XCTest
@testable import VigilKit

final class CodexAuthTests: XCTestCase {
    /// Builds an unsigned JWT with the given payload (header.payload.sig).
    private func makeJWT(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(b64url(header)).\(b64url(body)).sig"
    }

    func testIdentityReadsAccountIdFromTopLevelClaim() {
        let idToken = makeJWT([
            "chatgpt_account_id": "acct_top",
            "chatgpt_plan_type": "pro",
            "email": "you@example.com",
        ])
        let identity = CodexAuth.identity(fromIdToken: idToken)
        XCTAssertEqual(identity.accountId, "acct_top")
        XCTAssertEqual(identity.plan, "pro")
        XCTAssertEqual(identity.email, "you@example.com")
    }

    func testIdentityFallsBackToNestedAuthClaim() {
        let idToken = makeJWT([
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_nested",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let identity = CodexAuth.identity(fromIdToken: idToken)
        XCTAssertEqual(identity.accountId, "acct_nested")
        XCTAssertEqual(identity.plan, "plus")
    }

    func testCredentialsAreMintedWithAccountIdAndPlan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idToken = makeJWT([
            "chatgpt_account_id": "acct_123",
            "chatgpt_plan_type": "pro",
            "email": "you@example.com",
        ])
        let creds = CodexAuth.credentials(
            accessToken: "codex-access",
            refreshToken: "codex-refresh",
            idToken: idToken,
            expiresIn: 3600,
            now: now
        )
        let unwrapped = try! XCTUnwrap(creds)
        XCTAssertEqual(unwrapped.providerId, "codex")
        XCTAssertEqual(unwrapped.accessToken, "codex-access")
        XCTAssertEqual(unwrapped.refreshToken, "codex-refresh")
        XCTAssertEqual(unwrapped.accountId, "acct_123")
        XCTAssertEqual(unwrapped.plan, "pro")
        XCTAssertEqual(unwrapped.expiresAt, now.addingTimeInterval(3600))
        // "mint" so Vigil owns and refreshes this pair independently.
        XCTAssertEqual(unwrapped.source, TokenRefresher.mintSource)
        XCTAssertTrue(unwrapped.label?.contains("ChatGPT") == true)
    }

    func testCredentialsRejectTokensWithoutAnAccountId() {
        // Codex usage requires the ChatGPT-Account-Id header; no id = unusable.
        let idToken = makeJWT(["email": "you@example.com"])
        XCTAssertNil(CodexAuth.credentials(
            accessToken: "codex-access",
            refreshToken: nil,
            idToken: idToken,
            expiresIn: nil
        ))
    }

    func testCredentialsDeriveExpiryFromAccessTokenJWTWhenNoExpiresIn() {
        let idToken = makeJWT(["chatgpt_account_id": "acct_1"])
        let accessToken = makeJWT(["exp": 1_900_000_000])
        let creds = try! XCTUnwrap(CodexAuth.credentials(
            accessToken: accessToken,
            refreshToken: nil,
            idToken: idToken,
            expiresIn: nil
        ))
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    // MARK: - Device flow

    private let oauth = ProviderRegistry.codex.oauth!

    func testUserCodeRequestPostsClientIdJSON() throws {
        let request = try XCTUnwrap(CodexAuth.userCodeRequest(oauth: oauth))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/deviceauth/usercode")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
    }

    func testParseUserCodeHandlesStringIntervalAndAliasAndClampsToMinimum() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": "dev_1",
            "usercode": "WXYZ-1234",   // alias for user_code
            "interval": "0",           // string, and would busy-loop at 0
        ])
        let parsed = try XCTUnwrap(CodexAuth.parseUserCode(data))
        XCTAssertEqual(parsed.deviceAuthId, "dev_1")
        XCTAssertEqual(parsed.userCode, "WXYZ-1234")
        XCTAssertEqual(parsed.intervalSeconds, CodexAuth.minimumPollInterval)
    }

    func testVerificationURLIsTheCodexDevicePage() {
        XCTAssertEqual(CodexAuth.verificationURL(oauth: oauth)?.absoluteString, "https://auth.openai.com/codex/device")
    }

    func testPollTreats403And404AsPendingAndSuccessAsAuthorized() throws {
        XCTAssertEqual(CodexAuth.parsePoll(statusCode: 403, data: Data()), .pending)
        XCTAssertEqual(CodexAuth.parsePoll(statusCode: 404, data: Data()), .pending)
        XCTAssertEqual(CodexAuth.parsePoll(statusCode: 500, data: Data()), .failed)
        let success = try JSONSerialization.data(withJSONObject: [
            "authorization_code": "AUTHCODE",
            "code_challenge": "CHAL",
            "code_verifier": "VER",
        ])
        XCTAssertEqual(
            CodexAuth.parsePoll(statusCode: 200, data: success),
            .authorized(authorizationCode: "AUTHCODE", codeVerifier: "VER")
        )
    }

    func testExchangeRequestIsFormEncodedAuthorizationCodeGrant() throws {
        let request = CodexAuth.exchangeRequest(oauth: oauth, authorizationCode: "AUTHCODE", codeVerifier: "VER")
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=AUTHCODE"))
        XCTAssertTrue(body.contains("code_verifier=VER"))
        XCTAssertTrue(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        XCTAssertTrue(body.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
    }

    func testCredentialsFromTokenResponseParsesTopLevelTokens() throws {
        let idToken = makeJWT(["chatgpt_account_id": "acct_9", "chatgpt_plan_type": "pro"])
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": "acc",
            "refresh_token": "ref",
            "id_token": idToken,
        ])
        let creds = try XCTUnwrap(CodexAuth.credentials(fromTokenResponse: data))
        XCTAssertEqual(creds.providerId, "codex")
        XCTAssertEqual(creds.accountId, "acct_9")
        XCTAssertEqual(creds.refreshToken, "ref")
        XCTAssertEqual(creds.source, TokenRefresher.mintSource)
        // Codex minted tokens are refreshable via the shared refresher.
        let refresh = try XCTUnwrap(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.codex, credentials: creds)
        )
        XCTAssertEqual(refresh.url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let refreshBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(refresh.httpBody))
                as? [String: String]
        )
        XCTAssertEqual(
            refreshBody,
            [
                "grant_type": "refresh_token",
                "refresh_token": "ref",
                "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            ]
        )
    }
}

extension CodexAuthTests {
    /// `interval` is provider-controlled and feeds `UInt64(seconds * 1e9)` in
    /// the sign-in view. Converting a non-finite or huge Double to UInt64 is a
    /// runtime trap, not a throw, so it could not be caught — a malformed field
    /// would crash the app as soon as the Codex sign-in screen opened.
    func testHostilePollIntervalsAreClampedIntoASafeRange() throws {
        for raw in ["\"inf\"", "\"-inf\"", "\"nan\"", "\"1e20\"", "1e308", "-5", "99999"] {
            let json = "{\"device_auth_id\":\"d\",\"user_code\":\"ABCD-1234\",\"interval\":\(raw)}"
            let parsed = try XCTUnwrap(
                CodexAuth.parseUserCode(Data(json.utf8)),
                "should still parse with interval \(raw)"
            )
            XCTAssertTrue(parsed.intervalSeconds.isFinite, "interval \(raw) must be finite")
            XCTAssertGreaterThanOrEqual(parsed.intervalSeconds, CodexAuth.minimumPollInterval)
            XCTAssertLessThanOrEqual(parsed.intervalSeconds, CodexAuth.maximumPollInterval)
            // The conversion the view performs must not trap.
            let nanoseconds = UInt64(parsed.intervalSeconds * 1_000_000_000)
            XCTAssertGreaterThan(nanoseconds, 0)
        }
    }
}
