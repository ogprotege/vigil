import Foundation

/// On-device Grok Build sign-in via standard OIDC device authorization
/// (RFC 8628) against auth.x.ai. Pure request/response construction so it
/// unit-tests without a device or live account. Networking stays with the caller.
///
/// Minted pairs are `source: "mint"` so Vigil owns and renews them
/// independently (ADR-0005). Token requests use form-urlencoded bodies —
/// auth.x.ai rejects JSON with HTTP 415.
public enum GrokAuth {
    public static let minimumPollInterval: TimeInterval = 5
    public static let maximumPollInterval: TimeInterval = 60

    public struct DeviceCode: Equatable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURL: URL?
        public let intervalSeconds: TimeInterval
    }

    public enum PollResult: Equatable, Sendable {
        /// User has not approved yet — keep polling.
        case pending
        /// Server asked for a longer wait before the next poll.
        case slowDown(intervalSeconds: TimeInterval)
        /// Approved: access (and optional refresh) tokens are ready.
        case authorized(Credentials)
        /// Terminal failure (denied, expired, or unexpected status).
        case failed
    }

    /// Step 1: request a user code. Standard OIDC form body with client_id
    /// and the registry scopes.
    public static func userCodeRequest(oauth: OAuthEndpoint) -> URLRequest? {
        guard let url = oauth.deviceCodeUrl else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = [
            ("client_id", oauth.clientId),
            ("scope", oauth.scopes.joined(separator: " ")),
        ]
        request.httpBody = formURLEncoded(fields).data(using: .utf8)
        return request
    }

    public static func parseUserCode(_ data: Data) -> DeviceCode? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = usableToken(object["device_code"] as? String),
              let userCode = usableToken(object["user_code"] as? String)
        else { return nil }

        // A compromised token endpoint must not be able to send the user to
        // an arbitrary browser location. Accept only the documented xAI
        // device pages; keep the user code so they can still type it.
        let verification = pinnedVerificationURL(
            from: object["verification_uri_complete"] as? String
        ) ?? pinnedVerificationURL(from: object["verification_uri"] as? String)

        let rawInterval: TimeInterval
        if let number = object["interval"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            rawInterval = number.doubleValue
        } else if let text = object["interval"] as? String, let value = Double(text) {
            rawInterval = value
        } else {
            rawInterval = 0
        }
        let interval = rawInterval.isFinite
            ? min(max(minimumPollInterval, rawInterval), maximumPollInterval)
            : minimumPollInterval

        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verification,
            intervalSeconds: interval
        )
    }

    /// Step 2: poll the token endpoint with the device_code grant.
    public static func pollRequest(oauth: OAuthEndpoint, deviceCode: String) -> URLRequest? {
        guard let url = oauth.deviceTokenUrl ?? Optional(oauth.tokenUrl) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = RequestBuilder.timeoutInterval
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", deviceCode),
            ("client_id", oauth.clientId),
        ]
        request.httpBody = formURLEncoded(fields).data(using: .utf8)
        return request
    }

    /// Classifies a device-token poll response per RFC 8628.
    public static func parsePoll(
        statusCode: Int,
        data: Data,
        now: Date = Date()
    ) -> PollResult {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            switch error {
            case "authorization_pending":
                return .pending
            case "slow_down":
                let raw: TimeInterval
                if let number = object["interval"] as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID() {
                    raw = number.doubleValue
                } else {
                    raw = minimumPollInterval * 2
                }
                let interval = raw.isFinite
                    ? min(max(minimumPollInterval, raw), maximumPollInterval)
                    : minimumPollInterval * 2
                return .slowDown(intervalSeconds: interval)
            default:
                return .failed
            }
        }

        guard (200..<300).contains(statusCode),
              let credentials = credentials(fromTokenResponse: data, now: now)
        else {
            // 400 without a recognized pending error is terminal; other
            // non-2xx statuses are also terminal.
            if statusCode == 400 { return .failed }
            if (200..<300).contains(statusCode) { return .failed }
            // Some servers return 428/403 while pending without an error body.
            if statusCode == 403 || statusCode == 428 { return .pending }
            return .failed
        }
        return .authorized(credentials)
    }

    /// Builds a mint-sourced credential from a completed token response.
    public static func credentials(fromTokenResponse data: Data, now: Date = Date()) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = usableToken(object["access_token"] as? String)
        else { return nil }

        var credentials = Credentials(
            providerId: "grok",
            accessToken: accessToken,
            source: TokenRefresher.mintSource
        )
        credentials.refreshToken = usableToken(object["refresh_token"] as? String)
        let identity = identity(fromAccessToken: accessToken)
        credentials.accountId = identity.teamId ?? identity.principalId
        credentials.plan = identity.tier
        credentials.label = [
            "Grok Build",
            identity.teamId.map { "team \($0.prefix(8))" },
        ].compactMap { $0 }.joined(separator: " — ")

        if let expiresIn = object["expires_in"] as? NSNumber,
           CFGetTypeID(expiresIn) != CFBooleanGetTypeID() {
            let seconds = expiresIn.doubleValue
            if seconds.isFinite, seconds > 0, seconds <= 31_536_000 {
                credentials.expiresAt = now.addingTimeInterval(seconds)
            }
        } else if let expiry = expiry(fromAccessToken: accessToken) {
            credentials.expiresAt = expiry
        }
        return credentials
    }

    public struct Identity: Equatable, Sendable {
        public let principalId: String?
        public let teamId: String?
        public let tier: String?
    }

    public static func identity(fromAccessToken token: String) -> Identity {
        let payload = decodeJWTPayload(token)
        let tier: String?
        if let number = payload?["tier"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            tier = number.stringValue
        } else {
            tier = payload?["tier"] as? String
        }
        return Identity(
            principalId: payload?["principal_id"] as? String ?? payload?["sub"] as? String,
            teamId: payload?["team_id"] as? String,
            tier: tier
        )
    }

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

    private static func usableToken(_ raw: String?) -> String? {
        guard let token = raw,
              !token.isEmpty,
              token.utf8.count <= 65_536,
              token.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return token
    }

    private static let allowedVerificationHosts: Set<String> = [
        "accounts.x.ai",
        "auth.x.ai",
    ]

    /// Pins Grok's device-authorization browser page to xAI's HTTPS device
    /// path. Extra query keys, credentials, ports, and fragments are rejected.
    static func pinnedVerificationURL(from raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedVerificationHosts.contains(host),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "/oauth2/device"
        else { return nil }

        if let items = components.queryItems {
            let names = Set(items.compactMap { $0.name.isEmpty ? nil : $0.name })
            guard names.isSubset(of: ["user_code"]) else { return nil }
            if let code = items.first(where: { $0.name == "user_code" })?.value {
                guard !code.isEmpty,
                      code.utf8.count <= 128,
                      code.rangeOfCharacter(from: .controlCharacters) == nil
                else { return nil }
            }
        }
        return components.url
    }
}
