import Foundation

/// Pure construction/parsing for the OAuth refresh grant — the Swift twin of
/// cli/src/service.ts refreshClaude. Networking stays with the caller, like
/// the rest of VigilKit's provider layer.
///
/// Refresh is allowed only for credentials Vigil minted itself
/// (source == "mint"): rotating a copied pair would race the owning CLI's own
/// refresh-token rotation (ADR-0005).
public enum TokenRefresher {
    public static let mintSource = "mint"

    /// Returns nil when this credential must not (or cannot) be refreshed.
    public static func refreshRequest(spec: ProviderSpec, credentials: Credentials) -> URLRequest? {
        guard credentials.source == mintSource,
              let oauth = spec.oauth,
              let refreshToken = credentials.refreshToken,
              !refreshToken.isEmpty
        else { return nil }

        var request = URLRequest(url: oauth.tokenUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauth.clientId,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// A token usable for Bearer headers: non-empty, bounded, and free of
    /// control characters — the same screen QR-decoded credentials pass.
    private static func usableToken(_ raw: Any?) -> String? {
        guard let token = raw as? String,
              !token.isEmpty,
              token.utf8.count <= 65_536,
              token.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return token
    }

    /// Applies a successful token response. Returns nil when the body carries
    /// no usable access token (callers treat that as authExpired).
    public static func apply(responseBody: Data, to credentials: Credentials, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let accessToken = usableToken(object["access_token"])
        else { return nil }

        var updated = credentials
        updated.accessToken = accessToken
        if let refreshToken = usableToken(object["refresh_token"]) {
            updated.refreshToken = refreshToken
        }
        // The old expiry describes the token we just replaced — carrying it
        // forward would be wrong metadata either way, so absent or invalid
        // expires_in leaves the new expiry unknown. Refresh itself is
        // 401-driven, never expiry-driven, so nil is safe.
        updated.expiresAt = nil
        if let expiresIn = object["expires_in"] as? NSNumber,
           CFGetTypeID(expiresIn) != CFBooleanGetTypeID() {
            let seconds = expiresIn.doubleValue
            if seconds.isFinite, seconds > 0, seconds <= 31_536_000 {
                updated.expiresAt = now.addingTimeInterval(seconds)
            }
        }
        return updated
    }
}
