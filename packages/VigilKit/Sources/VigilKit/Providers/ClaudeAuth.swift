import CryptoKit
import Foundation
import Security

/// On-device Claude OAuth (authorization-code + PKCE). Networking stays with
/// the caller (like TokenRefresher); this type is pure request/URL construction
/// and response parsing so it unit-tests without a device.
///
/// The mobile lane uses the out-of-band `manualRedirectUri`: the browser shows
/// the authorization code, the user pastes it back, and the app exchanges it.
/// The minted pair is marked `source: "mint"` so TokenRefresher will renew it
/// (a hand-pasted token is deliberately never refreshed — ADR-0005).
public enum ClaudeAuth {
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Deterministic PKCE from caller-supplied entropy (used by tests and by the
    /// secure-random overload). challenge = base64url(SHA256(verifier)); state is
    /// the verifier itself — Anthropic's consent endpoint rejects a short random
    /// state (ADR-0005 / verified against Claude Code's convention).
    public static func generatePKCE(randomBytes: Data) -> PKCE {
        let verifier = base64URL(randomBytes)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge, state: verifier)
    }

    public enum PKCEGenerationError: Error, Equatable, Sendable {
        case secureRandomUnavailable
    }

    /// PKCE from 32 cryptographically-secure random bytes. Failure is
    /// surfaced instead of continuing with a zeroed challenge.
    public static func generatePKCE() throws -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PKCEGenerationError.secureRandomUnavailable
        }
        return generatePKCE(randomBytes: Data(bytes))
    }

    public static func authorizeURL(
        oauth: OAuthEndpoint,
        redirectURI: String,
        challenge: String,
        state: String
    ) -> URL {
        var components = URLComponents(url: oauth.authorizeUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Anthropic's authorize endpoint rejects requests without code=true.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: oauth.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: oauth.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Parses whatever the user pastes after authorizing: a full callback URL, a
    /// "code#state" pair, "code&state=…", or a bare code. Returns the code only
    /// when the state matches (bare/hashless input assumes the expected state).
    /// Accepts the callback forms Claude may return to the mobile flow.
    public static func parsePastedCode(_ input: String, expectedState: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = firstMatch(in: text, pattern: "[?&]code=([^&\\s]+)(?:&state=([^&\\s]+))?") {
            let code = (match.0.removingPercentEncoding ?? match.0)
            let state = match.1.map { $0.removingPercentEncoding ?? $0 } ?? expectedState
            return state == expectedState ? code : nil
        }
        if let match = firstMatch(in: text, pattern: "^([^#&\\s]+)(?:(?:#|&state=)([^&\\s]+))?$") {
            let state = match.1 ?? expectedState
            return state == expectedState ? match.0 : nil
        }
        return nil
    }

    public static func exchangeRequest(
        oauth: OAuthEndpoint,
        code: String,
        redirectURI: String,
        verifier: String,
        state: String
    ) -> URLRequest {
        var request = URLRequest(url: oauth.tokenUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": oauth.clientId,
            "code_verifier": verifier,
            "state": state,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Builds a minted Claude credential from a token response. Returns nil when
    /// no usable access token is present (callers treat that as a failed sign-in).
    public static func credentials(fromExchange responseBody: Data, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let accessToken = usableToken(object["access_token"])
        else { return nil }

        var credentials = Credentials(
            providerId: "claude",
            accessToken: accessToken,
            source: TokenRefresher.mintSource
        )
        if let refreshToken = usableToken(object["refresh_token"]) {
            credentials.refreshToken = refreshToken
        }
        if let expiresIn = object["expires_in"] as? NSNumber,
           CFGetTypeID(expiresIn) != CFBooleanGetTypeID() {
            let seconds = expiresIn.doubleValue
            if seconds.isFinite, seconds > 0, seconds <= 31_536_000 {
                credentials.expiresAt = now.addingTimeInterval(seconds)
            }
        }
        return credentials
    }

    // MARK: - Helpers

    private static func usableToken(_ raw: Any?) -> String? {
        guard let token = raw as? String,
              !token.isEmpty,
              token.utf8.count <= 65_536,
              token.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return token
    }

    /// Returns the first and (optional) second capture group of the first match.
    private static func firstMatch(in text: String, pattern: String) -> (String, String?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges,
                  let r = Range(match.range(at: index), in: text)
            else { return nil }
            return String(text[r])
        }
        guard let first = group(1) else { return nil }
        return (first, group(2))
    }
}
