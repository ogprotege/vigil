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

    /// Applies a successful token response. Returns nil when the body carries
    /// no usable access token (callers treat that as authExpired).
    public static func apply(responseBody: Data, to credentials: Credentials, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty,
              accessToken.utf8.count <= 65_536
        else { return nil }

        var updated = credentials
        updated.accessToken = accessToken
        if let refreshToken = object["refresh_token"] as? String,
           !refreshToken.isEmpty,
           refreshToken.utf8.count <= 65_536 {
            updated.refreshToken = refreshToken
        }
        if let expiresIn = object["expires_in"] as? NSNumber {
            let seconds = expiresIn.doubleValue
            if seconds.isFinite, seconds > 0, seconds <= 31_536_000 {
                updated.expiresAt = now.addingTimeInterval(seconds)
            }
        }
        return updated
    }
}
