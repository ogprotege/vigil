import CryptoKit
import Foundation
import XCTest
@testable import VigilKit

final class OpenRouterAuthTests: XCTestCase {
    private let bytes = Data(0..<32)

    func testPKCEUsesRFC7636LengthAlphabetAndS256Challenge() throws {
        let pkce = try XCTUnwrap(OpenRouterAuth.generatePKCE(randomBytes: bytes))

        XCTAssertEqual(pkce.verifier.utf8.count, 43)
        XCTAssertEqual(pkce.challenge.utf8.count, 43)
        let base64URLAlphabet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: base64URLAlphabet.inverted))
        XCTAssertNil(pkce.challenge.rangeOfCharacter(from: base64URLAlphabet.inverted))

        let expectedChallenge = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.challenge, expectedChallenge)
        XCTAssertNil(OpenRouterAuth.generatePKCE(randomBytes: Data(repeating: 0, count: 31)))
        XCTAssertNil(OpenRouterAuth.generatePKCE(randomBytes: Data(repeating: 0, count: 33)))
    }

    func testSecureRandomPKCEHasValidLengthAndAlphabet() throws {
        let pkce = try OpenRouterAuth.generatePKCE()
        XCTAssertEqual(pkce.verifier.utf8.count, 43)
        XCTAssertEqual(pkce.challenge.utf8.count, 43)
    }

    func testAuthorizeURLIsPinnedAndHasOnlyOfficialHeadlessParameters() throws {
        let pkce = try XCTUnwrap(OpenRouterAuth.generatePKCE(randomBytes: bytes))
        let url = try XCTUnwrap(OpenRouterAuth.authorizeURL(pkce: pkce))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "openrouter.ai")
        XCTAssertEqual(components.path, "/auth")
        XCTAssertEqual(components.port, nil)
        XCTAssertEqual(values["code_challenge"]!, pkce.challenge)
        XCTAssertEqual(values["code_challenge_method"]!, "S256")
        XCTAssertEqual(values["key_label"]!, "Vigil")
        XCTAssertFalse(values.keys.contains("callback_url"))
        XCTAssertEqual(Set(values.keys), ["code_challenge", "code_challenge_method", "key_label"])
    }

    func testAuthorizeURLRejectsChallengeThatDoesNotMatchVerifier() throws {
        let pkce = try XCTUnwrap(OpenRouterAuth.generatePKCE(randomBytes: bytes))
        let mismatched = OpenRouterAuth.PKCE(
            verifier: pkce.verifier,
            challenge: String(repeating: "A", count: 43)
        )
        XCTAssertNil(OpenRouterAuth.authorizeURL(pkce: mismatched))
    }

    func testExchangeRequestUsesPinnedJSONContractAndNoSecretsInURL() throws {
        let pkce = try XCTUnwrap(OpenRouterAuth.generatePKCE(randomBytes: bytes))
        let request = try XCTUnwrap(
            OpenRouterAuth.exchangeRequest(code: "  one-time-code  ", verifier: pkce.verifier)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, RequestBuilder.timeoutInterval)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("one-time-code"))
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains(pkce.verifier))

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, [
            "code": "one-time-code",
            "code_verifier": pkce.verifier,
            "code_challenge_method": "S256",
        ])
    }

    func testExchangeRequestRejectsMalformedCodeAndVerifier() throws {
        let pkce = try XCTUnwrap(OpenRouterAuth.generatePKCE(randomBytes: bytes))
        XCTAssertNil(OpenRouterAuth.exchangeRequest(code: "", verifier: pkce.verifier))
        XCTAssertNil(OpenRouterAuth.exchangeRequest(code: "has whitespace", verifier: pkce.verifier))
        XCTAssertNil(OpenRouterAuth.exchangeRequest(code: "code", verifier: "too-short"))
        XCTAssertNil(
            OpenRouterAuth.exchangeRequest(
                code: "code",
                verifier: String(repeating: "a", count: 42) + "/"
            )
        )
    }

    func testCredentialsFromExchangeAreManualAndNonRefreshing() throws {
        let response = try JSONSerialization.data(withJSONObject: ["key": "sk-or-v1-example"])
        let credentials = try XCTUnwrap(OpenRouterAuth.credentials(fromExchange: response))

        XCTAssertEqual(credentials.providerId, "openrouter")
        XCTAssertEqual(credentials.accessToken, "sk-or-v1-example")
        XCTAssertEqual(credentials.source, "manual")
        XCTAssertNil(credentials.refreshToken)
        XCTAssertNil(credentials.expiresAt)
        XCTAssertNil(
            TokenRefresher.refreshRequest(
                spec: ProviderRegistry.openRouter,
                credentials: credentials
            )
        )
    }

    func testTransportFailureDoesNotConsumeAuthorizationChallenge() {
        XCTAssertFalse(
            OpenRouterAuth.shouldResetAuthorization(
                afterTransportError: URLError(.notConnectedToInternet)
            )
        )
        XCTAssertFalse(
            OpenRouterAuth.shouldResetAuthorization(
                afterTransportError: URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            OpenRouterAuth.shouldResetAuthorization(
                afterTransportError: URLError(.networkConnectionLost)
            )
        )
    }

    func testCredentialsFromExchangeRejectMalformedResponses() throws {
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data("not-json".utf8)))
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data("{}".utf8)))
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data(#"{"key":42}"#.utf8)))
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data(#"{"key":""}"#.utf8)))
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data(#"{"key":"bad key"}"#.utf8)))
        XCTAssertNil(OpenRouterAuth.credentials(fromExchange: Data(#"{"key":"bad\nkey"}"#.utf8)))
    }
}
