import CryptoKit
import Foundation
import Security

/// OpenRouter's headless OAuth PKCE flow.
///
/// Vigil opens OpenRouter's fixed authorization page without a callback URL.
/// After approval, the user copies the one-time code back into Vigil, which
/// exchanges it for an API key. Networking stays with the caller; this type
/// only constructs pinned requests and parses opaque responses. It never logs
/// authorization codes, PKCE verifiers, API keys, or provider error bodies.
public enum OpenRouterAuth {
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String
    }

    /// A deliberately non-diagnostic error: callers can explain that secure
    /// randomness was unavailable without accidentally including secret data.
    public enum PKCEGenerationError: Error, Equatable, Sendable {
        case secureRandomUnavailable
    }

    private static let authorizeEndpoint = URL(string: "https://openrouter.ai/auth")!
    private static let exchangeEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    private static let verifierByteCount = 32
    private static let maximumOpaqueValueBytes = 65_536

    /// Deterministic PKCE derivation for tests. Exactly 32 bytes encode to the
    /// RFC 7636 minimum verifier length (43 base64url characters).
    static func generatePKCE(randomBytes: Data) -> PKCE? {
        guard randomBytes.count == verifierByteCount else { return nil }
        let verifier = base64URL(randomBytes)
        guard isValidVerifier(verifier) else { return nil }
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCE(verifier: verifier, challenge: base64URL(Data(digest)))
    }

    /// Generates a verifier from 256 bits of cryptographically secure system
    /// randomness. Failure is surfaced instead of continuing with zero bytes.
    public static func generatePKCE() throws -> PKCE {
        var bytes = [UInt8](repeating: 0, count: verifierByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
              let pkce = generatePKCE(randomBytes: Data(bytes))
        else {
            throw PKCEGenerationError.secureRandomUnavailable
        }
        return pkce
    }

    /// Builds the fixed OpenRouter consent URL. OpenRouter's headless flow must
    /// not include `callback_url`; the approved code is copied back by the user.
    public static func authorizeURL(pkce: PKCE) -> URL? {
        guard isValidVerifier(pkce.verifier),
              pkce.challenge == challenge(forVerifier: pkce.verifier),
              var components = URLComponents(
                  url: authorizeEndpoint,
                  resolvingAgainstBaseURL: false
              )
        else { return nil }

        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: "Vigil"),
        ]
        guard let url = components.url, isPinnedAuthorizeURL(url) else { return nil }
        return url
    }

    /// Redeems the user-pasted, single-use code at OpenRouter's fixed exchange
    /// endpoint. JSON serialization keeps both opaque values out of the URL.
    public static func exchangeRequest(code: String, verifier: String) -> URLRequest? {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableOpaqueValue(trimmedCode),
              !trimmedCode.contains(where: { $0.isWhitespace }),
              isValidVerifier(verifier),
              isPinnedExchangeURL(exchangeEndpoint)
        else { return nil }

        var request = URLRequest(url: exchangeEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "code": trimmedCode,
                "code_verifier": verifier,
                "code_challenge_method": "S256",
            ],
            options: [.sortedKeys]
        )
        guard request.httpBody != nil else { return nil }
        return request
    }

    /// A transport error does not consume OpenRouter's one-time code or the
    /// S256 challenge that minted it. Only a completed HTTP rejection or an
    /// unparseable body should force a new authorization.
    public static func shouldResetAuthorization(afterTransportError error: Error) -> Bool {
        _ = error
        return false
    }

    /// Turns a successful exchange response into a copied/manual OpenRouter
    /// credential. It has no refresh token or expiry and will never enter the
    /// refresh-token path used by Vigil-owned OAuth token pairs.
    public static func credentials(fromExchange responseBody: Data) -> Credentials? {
        guard responseBody.count <= maximumOpaqueValueBytes,
              let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let key = object["key"] as? String,
              isUsableOpaqueValue(key),
              !key.contains(where: { $0.isWhitespace })
        else { return nil }

        return Credentials(
            providerId: "openrouter",
            accessToken: key,
            source: "manual"
        )
    }

    // MARK: - Validation

    private static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isValidVerifier(_ verifier: String) -> Bool {
        guard (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122, 126:
                return true
            default:
                return false
            }
        }) else { return false }
        return true
    }

    private static func isUsableOpaqueValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumOpaqueValueBytes
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isPinnedAuthorizeURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "openrouter.ai"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/auth"
            && components.fragment == nil
    }

    private static func isPinnedExchangeURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "openrouter.ai"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/api/v1/auth/keys"
            && components.query == nil
            && components.fragment == nil
    }
}
