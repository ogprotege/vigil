import Foundation
import XCTest
@testable import VigilKit

final class GrokAuthTests: XCTestCase {
    private var oauth: OAuthEndpoint { ProviderRegistry.grok.oauth! }

    func testUserCodeRequestIsFormEncodedWithScopes() throws {
        let request = try XCTUnwrap(GrokAuth.userCodeRequest(oauth: oauth))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://auth.x.ai/oauth2/device/code"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("client_id=b1a00492-073a-47ea-816f-4c329264a828"))
        XCTAssertTrue(body.contains("scope="))
        XCTAssertTrue(body.contains("grok-cli%3Aaccess") || body.contains("grok-cli:access"))
        XCTAssertTrue(body.contains("offline_access"))
    }

    func testParseUserCodeClampsIntervalAndReadsVerificationURI() throws {
        let data = Data("""
        {
          "device_code": "dev-code-1",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://accounts.x.ai/oauth2/device",
          "verification_uri_complete": "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH",
          "expires_in": 1800,
          "interval": 0
        }
        """.utf8)
        let device = try XCTUnwrap(GrokAuth.parseUserCode(data))
        XCTAssertEqual(device.deviceCode, "dev-code-1")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(
            device.verificationURL?.absoluteString,
            "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH"
        )
        XCTAssertEqual(device.intervalSeconds, GrokAuth.minimumPollInterval)

        XCTAssertNil(GrokAuth.parseUserCode(Data("{}".utf8)))
        XCTAssertNil(GrokAuth.parseUserCode(Data("not-json".utf8)))
    }

    func testPollRequestUsesDeviceCodeGrant() throws {
        let request = try XCTUnwrap(
            GrokAuth.pollRequest(oauth: oauth, deviceCode: "dev-code-1")
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://auth.x.ai/oauth2/token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(
            body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
                || body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code")
        )
        XCTAssertTrue(body.contains("device_code=dev-code-1"))
        XCTAssertTrue(body.contains("client_id=b1a00492-073a-47ea-816f-4c329264a828"))
    }

    func testParsePollPendingSlowDownAndAuthorized() throws {
        XCTAssertEqual(
            GrokAuth.parsePoll(
                statusCode: 400,
                data: Data(#"{"error":"authorization_pending"}"#.utf8)
            ),
            .pending
        )

        if case .slowDown(let interval) = GrokAuth.parsePoll(
            statusCode: 400,
            data: Data(#"{"error":"slow_down","interval":12}"#.utf8)
        ) {
            XCTAssertEqual(interval, 12)
        } else {
            XCTFail("expected slow_down")
        }

        XCTAssertEqual(
            GrokAuth.parsePoll(
                statusCode: 400,
                data: Data(#"{"error":"access_denied"}"#.utf8)
            ),
            .failed
        )

        // Minimal JWT payload: {"team_id":"team-abc","principal_id":"user-1","tier":1,"exp":2000000000}
        let header = Data(#"{"alg":"none"}"#.utf8).base64URL
        let payload = Data(
            #"{"team_id":"team-abc","principal_id":"user-1","tier":1,"exp":2000000000}"#.utf8
        ).base64URL
        let access = "\(header).\(payload).sig"
        let tokenBody = Data("""
        {
          "access_token": "\(access)",
          "refresh_token": "refresh-1",
          "expires_in": 21600,
          "token_type": "Bearer"
        }
        """.utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard case .authorized(let credentials) = GrokAuth.parsePoll(
            statusCode: 200,
            data: tokenBody,
            now: now
        ) else {
            return XCTFail("expected authorized credentials")
        }
        XCTAssertEqual(credentials.providerId, "grok")
        XCTAssertEqual(credentials.accessToken, access)
        XCTAssertEqual(credentials.refreshToken, "refresh-1")
        XCTAssertEqual(credentials.source, TokenRefresher.mintSource)
        XCTAssertEqual(credentials.accountId, "team-abc")
        XCTAssertEqual(credentials.plan, "1")
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(21_600))
        XCTAssertNotNil(TokenRefresher.refreshRequest(spec: ProviderRegistry.grok, credentials: credentials))
    }

    func testRefreshRequestIsFormURLEncoded() throws {
        let credentials = Credentials(
            providerId: "grok",
            accessToken: "access",
            refreshToken: "refresh-xyz",
            source: TokenRefresher.mintSource
        )
        let request = try XCTUnwrap(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.grok, credentials: credentials)
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=refresh-xyz"))
        XCTAssertTrue(body.contains("client_id=b1a00492-073a-47ea-816f-4c329264a828"))
        XCTAssertNil(
            TokenRefresher.refreshRequest(
                spec: ProviderRegistry.grok,
                credentials: Credentials(
                    providerId: "grok",
                    accessToken: "access",
                    refreshToken: "refresh-xyz",
                    source: "manual"
                )
            ),
            "manual Grok tokens must not be refreshed (ADR-0005)"
        )
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
