import Foundation

public enum ResetFormat: String, Sendable, Equatable {
    case iso8601
    case unixSeconds
}

public struct WindowMapping: Sendable, Equatable {
    public let id: String
    public let sourceKey: String
    public let resetFormat: ResetFormat
    public let windowSeconds: Int?
    public let secondary: Bool

    public init(id: String, sourceKey: String, resetFormat: ResetFormat, windowSeconds: Int?, secondary: Bool) {
        self.id = id
        self.sourceKey = sourceKey
        self.resetFormat = resetFormat
        self.windowSeconds = windowSeconds
        self.secondary = secondary
    }
}

public struct PollPolicy: Sendable, Equatable {
    public let minSeconds: TimeInterval
    public let jitterSeconds: TimeInterval
    public let backoff429BaseSeconds: TimeInterval
    public let backoffMaxSeconds: TimeInterval

    public init(minSeconds: TimeInterval, jitterSeconds: TimeInterval, backoff429BaseSeconds: TimeInterval, backoffMaxSeconds: TimeInterval) {
        self.minSeconds = minSeconds
        self.jitterSeconds = jitterSeconds
        self.backoff429BaseSeconds = backoff429BaseSeconds
        self.backoffMaxSeconds = backoffMaxSeconds
    }
}

public struct ResponseFields: Sendable, Equatable {
    public let utilization: String
    public let resetsAt: String
    public let windowSeconds: String?

    public init(utilization: String, resetsAt: String, windowSeconds: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }
}

public struct AdditionalWindows: Sendable, Equatable {
    public let sourceKey: String
    public let idKey: String
    public let secondary: Bool

    public init(sourceKey: String, idKey: String, secondary: Bool) {
        self.sourceKey = sourceKey
        self.idKey = idKey
        self.secondary = secondary
    }
}

/// The subset of the provider's oauth block the app needs at runtime: the
/// refresh grant. Mint/authorize flows stay in the CLI.
public struct OAuthEndpoint: Sendable, Equatable {
    public let tokenUrl: URL
    public let clientId: String

    public init(tokenUrl: URL, clientId: String) {
        self.tokenUrl = tokenUrl
        self.clientId = clientId
    }
}

public struct ProviderSpec: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let usageMethod: String
    public let usageURL: URL
    /// Header templates; "{access_token}" / "{account_id}" substituted at request time.
    public let headers: [String: String]
    public let poll: PollPolicy
    public let responseFields: ResponseFields
    public let planKey: String?
    public let additionalWindows: AdditionalWindows?
    public let windows: [WindowMapping]
    /// Non-nil only for providers whose refresh grant is verified (Claude).
    public let oauth: OAuthEndpoint?

    public init(
        id: String,
        displayName: String,
        usageMethod: String,
        usageURL: URL,
        headers: [String: String],
        poll: PollPolicy,
        responseFields: ResponseFields,
        planKey: String?,
        additionalWindows: AdditionalWindows?,
        windows: [WindowMapping],
        oauth: OAuthEndpoint? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.usageMethod = usageMethod
        self.usageURL = usageURL
        self.headers = headers
        self.poll = poll
        self.responseFields = responseFields
        self.planKey = planKey
        self.additionalWindows = additionalWindows
        self.windows = windows
        self.oauth = oauth
    }
}

/// Hand-mirrored from protocol/providers.json for runtime independence.
/// SpecParityTests asserts these constants match the JSON — drift fails CI.
public enum ProviderRegistry {
    public static let claude = ProviderSpec(
        id: "claude",
        displayName: "Claude",
        usageMethod: "GET",
        usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        headers: [
            "Authorization": "Bearer {access_token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-code/2.1.32",
        ],
        poll: PollPolicy(minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
        responseFields: ResponseFields(utilization: "utilization", resetsAt: "resets_at", windowSeconds: nil),
        planKey: nil,
        additionalWindows: nil,
        windows: [
            WindowMapping(id: "session", sourceKey: "five_hour", resetFormat: .iso8601, windowSeconds: 18000, secondary: false),
            WindowMapping(id: "weekly", sourceKey: "seven_day", resetFormat: .iso8601, windowSeconds: 604_800, secondary: false),
            WindowMapping(id: "weekly_sonnet", sourceKey: "seven_day_sonnet", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
            WindowMapping(id: "weekly_opus", sourceKey: "seven_day_opus", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
        ],
        oauth: OAuthEndpoint(
            tokenUrl: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            clientId: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        )
    )

    public static let codex = ProviderSpec(
        id: "codex",
        displayName: "ChatGPT / Codex",
        usageMethod: "GET",
        usageURL: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        headers: [
            "Authorization": "Bearer {access_token}",
            "ChatGPT-Account-Id": "{account_id}",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs/0.34.0",
        ],
        poll: PollPolicy(minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
        responseFields: ResponseFields(utilization: "used_percent", resetsAt: "reset_at", windowSeconds: "limit_window_seconds"),
        planKey: "plan_type",
        additionalWindows: AdditionalWindows(sourceKey: "additional_rate_limits", idKey: "name", secondary: true),
        windows: [
            WindowMapping(id: "session", sourceKey: "rate_limit.primary_window", resetFormat: .unixSeconds, windowSeconds: nil, secondary: false),
            WindowMapping(id: "weekly", sourceKey: "rate_limit.secondary_window", resetFormat: .unixSeconds, windowSeconds: nil, secondary: false),
        ]
    )

    public static let all: [ProviderSpec] = [claude, codex]

    public static func spec(for id: String) -> ProviderSpec? {
        all.first { $0.id == id }
    }
}
