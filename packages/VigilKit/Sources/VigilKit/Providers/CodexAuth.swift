import Foundation

/// On-device Codex (ChatGPT) sign-in via OpenAI's OAuth **device-code** flow —
/// the fully-on-phone path (no computer, no redirect handling): request a user
/// code, the user approves it in a browser, and we poll for tokens.
///
/// This type is pure request/response construction so it unit-tests without a
/// device or a live account. Networking and polling loops stay with the caller.
/// The minted pair is marked `source: "mint"` so Vigil renews it independently
/// of the Codex CLI (the "mint, don't copy" posture of ADR-0005).
public enum CodexAuth {
    public struct Identity: Equatable, Sendable {
        public let accountId: String?
        public let plan: String?
        public let email: String?
    }

    /// Decodes a JWT's payload (base64url, unverified — we only read claims the
    /// provider already sent us, exactly like cli/src/util/jwt.ts).
    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Reads the account id / plan / email from a Codex id_token, with the same
    /// fallback order Vigil's CLI discovery uses (top-level claim, then the
    /// nested `https://api.openai.com/auth` object).
    public static func identity(fromIdToken idToken: String?) -> Identity {
        let payload = idToken.flatMap { decodeJWTPayload($0) }
        return Identity(
            accountId: claim(payload, "chatgpt_account_id"),
            plan: claim(payload, "chatgpt_plan_type"),
            email: payload?["email"] as? String
        )
    }

    /// Builds a Codex credential from a completed device-flow token set. Returns
    /// nil without a usable access token or an account id (the usage endpoint's
    /// `ChatGPT-Account-Id` header needs the id, so a credential without one is
    /// unusable).
    public static func credentials(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresIn: Double?,
        now: Date = Date()
    ) -> Credentials? {
        guard let access = usableToken(accessToken) else { return nil }
        let identity = identity(fromIdToken: idToken)
        guard let accountId = identity.accountId else { return nil }

        var credentials = Credentials(
            providerId: "codex",
            accessToken: access,
            source: TokenRefresher.mintSource
        )
        credentials.refreshToken = refreshToken.flatMap { usableToken($0) }
        credentials.accountId = accountId
        credentials.plan = identity.plan
        credentials.label = [
            identity.plan.map { "ChatGPT (\($0))" } ?? "ChatGPT",
            identity.email,
        ].compactMap { $0 }.joined(separator: " — ")
        if let expiresIn, expiresIn.isFinite, expiresIn > 0, expiresIn <= 31_536_000 {
            credentials.expiresAt = now.addingTimeInterval(expiresIn)
        } else if let expiry = expiry(fromAccessToken: access) {
            // The device-flow token response carries no expires_in; the CLI reads
            // it from the access-token JWT's `exp` claim, so we do the same.
            credentials.expiresAt = expiry
        }
        return credentials
    }

    // MARK: - Device-authorization flow

    /// Minimum poll interval — the server can send `0`, which would busy-loop.
    public static let minimumPollInterval: TimeInterval = 5

    public struct DeviceCode: Equatable, Sendable {
        public let deviceAuthId: String
        public let userCode: String
        public let intervalSeconds: TimeInterval
    }

    public enum PollResult: Equatable, Sendable {
        /// The user hasn't approved yet (HTTP 403/404) — keep polling.
        case pending
        /// Approved: the server handed back an auth code + its PKCE verifier.
        case authorized(authorizationCode: String, codeVerifier: String)
        /// A terminal failure (denied, expired, or an unexpected status).
        case failed
    }

    /// The page the user opens to enter the code (the server doesn't return it;
    /// the CLI constructs `{issuer}/codex/device`).
    public static func verificationURL(oauth: OAuthEndpoint) -> URL? {
        guard let device = oauth.deviceCodeUrl,
              var components = URLComponents(url: device, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/codex/device"
        components.query = nil
        return components.url
    }

    /// Step 1: request a user code. Body is exactly `{ "client_id": … }`.
    public static func userCodeRequest(oauth: OAuthEndpoint) -> URLRequest? {
        guard let url = oauth.deviceCodeUrl else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["client_id": oauth.clientId], options: [.sortedKeys]
        )
        return request
    }

    public static func parseUserCode(_ data: Data) -> DeviceCode? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthId = object["device_auth_id"] as? String,
              let userCode = (object["user_code"] ?? object["usercode"]) as? String
        else { return nil }
        let rawInterval: TimeInterval
        if let number = object["interval"] as? NSNumber { rawInterval = number.doubleValue }
        else if let text = object["interval"] as? String, let value = Double(text) { rawInterval = value }
        else { rawInterval = 0 }
        return DeviceCode(
            deviceAuthId: deviceAuthId,
            userCode: userCode,
            intervalSeconds: max(minimumPollInterval, rawInterval)
        )
    }

    /// Step 2: poll for approval. Body is exactly `{ device_auth_id, user_code }`.
    public static func pollRequest(oauth: OAuthEndpoint, deviceAuthId: String, userCode: String) -> URLRequest? {
        guard let url = oauth.deviceTokenUrl else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["device_auth_id": deviceAuthId, "user_code": userCode],
            options: [.sortedKeys]
        )
        return request
    }

    /// Classifies a poll response: 403/404 mean "keep waiting"; a 2xx body
    /// carries the authorization code + PKCE verifier; anything else is fatal.
    public static func parsePoll(statusCode: Int, data: Data) -> PollResult {
        if statusCode == 403 || statusCode == 404 { return .pending }
        guard (200..<300).contains(statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["authorization_code"] as? String,
              let verifier = object["code_verifier"] as? String
        else { return .failed }
        return .authorized(authorizationCode: code, codeVerifier: verifier)
    }

    /// Step 3: redeem the authorization code for tokens at /oauth/token. The
    /// device-flow exchange is form-urlencoded (unlike Claude's JSON exchange).
    public static func exchangeRequest(
        oauth: OAuthEndpoint,
        authorizationCode: String,
        codeVerifier: String
    ) -> URLRequest {
        var request = URLRequest(url: oauth.tokenUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("grant_type", "authorization_code"),
            ("code", authorizationCode),
            ("redirect_uri", oauth.manualRedirectUri),
            ("client_id", oauth.clientId),
            ("code_verifier", codeVerifier),
        ]
        request.httpBody = formURLEncoded(fields).data(using: .utf8)
        return request
    }

    /// Parses the /oauth/token response: top-level id_token/access_token/refresh_token.
    public static func credentials(fromTokenResponse data: Data, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String
        else { return nil }
        return credentials(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            idToken: object["id_token"] as? String,
            expiresIn: nil,
            now: now
        )
    }

    // MARK: - Helpers

    private static func expiry(fromAccessToken token: String) -> Date? {
        guard let payload = decodeJWTPayload(token),
              let exp = payload["exp"] as? NSNumber,
              CFGetTypeID(exp) != CFBooleanGetTypeID()
        else { return nil }
        let seconds = exp.doubleValue
        guard seconds.isFinite, seconds > 0, seconds <= 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formURLEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static func claim(_ payload: [String: Any]?, _ key: String) -> String? {
        guard let payload else { return nil }
        if let direct = payload[key] as? String { return direct }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let nested = auth[key] as? String {
            return nested
        }
        return nil
    }

    private static func usableToken(_ raw: String?) -> String? {
        guard let token = raw,
              !token.isEmpty,
              token.utf8.count <= 65_536,
              token.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return token
    }
}
