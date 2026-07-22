import Foundation

public enum ResetFormat: String, Sendable, Equatable {
    case iso8601
    case unixSeconds
    case unixMillis
}

/// Per-window override of the provider's responseFields (e.g. MiniMax keeps
/// session and weekly numbers under different keys of one bucket).
public struct WindowFieldOverride: Sendable, Equatable {
    public let utilization: String
    public let resetsAt: String

    public init(utilization: String, resetsAt: String) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct WindowMapping: Sendable, Equatable {
    public let id: String
    public let sourceKey: String
    public let resetFormat: ResetFormat
    public let windowSeconds: Int?
    public let secondary: Bool
    public let fields: WindowFieldOverride?

    public init(
        id: String,
        sourceKey: String,
        resetFormat: ResetFormat,
        windowSeconds: Int?,
        secondary: Bool,
        fields: WindowFieldOverride? = nil
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.resetFormat = resetFormat
        self.windowSeconds = windowSeconds
        self.secondary = secondary
        self.fields = fields
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

/// "remaining" inverts the percentage (utilization = 100 - value) for
/// providers that report quota left instead of quota used.
public enum UtilizationKind: String, Sendable, Equatable {
    case used
    case remaining
}

public struct ResponseFields: Sendable, Equatable {
    public let utilization: String
    public let resetsAt: String
    public let windowSeconds: String?
    public let utilizationKind: UtilizationKind
    /// Providers that serialize window numbers as JSON strings ("46.5").
    public let allowStringNumbers: Bool

    public init(
        utilization: String,
        resetsAt: String,
        windowSeconds: String?,
        utilizationKind: UtilizationKind = .used,
        allowStringNumbers: Bool = false
    ) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.utilizationKind = utilizationKind
        self.allowStringNumbers = allowStringNumbers
    }
}

/// Keep only entries whose `key` string-equals `equals`.
public struct AdditionalWindowFilter: Sendable, Equatable {
    public let key: String
    public let equals: String

    public init(key: String, equals: String) {
        self.key = key
        self.equals = equals
    }
}

public struct AdditionalWindows: Sendable, Equatable {
    public let sourceKey: String
    public let idKey: String
    public let secondary: Bool
    public let filter: AdditionalWindowFilter?
    public let resetFormat: ResetFormat
    /// When set, the id is `${idPrefix}_${normalized(idKey value)}`; absent
    /// means the raw idKey value is the id (Codex lanes).
    public let idPrefix: String?
    public let labelKey: String?
    public let windowSeconds: Int?
    public let fields: WindowFieldOverride?

    public init(
        sourceKey: String,
        idKey: String,
        secondary: Bool,
        filter: AdditionalWindowFilter? = nil,
        resetFormat: ResetFormat = .unixSeconds,
        idPrefix: String? = nil,
        labelKey: String? = nil,
        windowSeconds: Int? = nil,
        fields: WindowFieldOverride? = nil
    ) {
        self.sourceKey = sourceKey
        self.idKey = idKey
        self.secondary = secondary
        self.filter = filter
        self.resetFormat = resetFormat
        self.idPrefix = idPrefix
        self.labelKey = labelKey
        self.windowSeconds = windowSeconds
        self.fields = fields
    }
}

public enum MetricAggregate: String, Sendable, Equatable {
    /// Adds every value the sourceKey resolves to; path segments ending in
    /// [] flat-map arrays (billing APIs return time buckets).
    case sum
}

public struct MetricMapping: Sendable, Equatable {
    public let id: String
    public let label: String
    public let sourceKey: String
    public let kind: UsageMetricKind
    public let unit: String?
    /// Dot-path to a unit/currency string in the response; overrides `unit`
    /// when it resolves (e.g. Claude extra_usage.currency).
    public let unitKey: String?
    public let secondary: Bool
    public let aggregate: MetricAggregate?
    /// Multiplier applied after resolution (0.01 converts cents to dollars).
    public let scale: Double?

    public init(
        id: String,
        label: String,
        sourceKey: String,
        kind: UsageMetricKind,
        unit: String?,
        secondary: Bool,
        unitKey: String? = nil,
        aggregate: MetricAggregate? = nil,
        scale: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.sourceKey = sourceKey
        self.kind = kind
        self.unit = unit
        self.unitKey = unitKey
        self.secondary = secondary
        self.aggregate = aggregate
        self.scale = scale
    }
}

public struct MetricCollectionMapping: Sendable, Equatable {
    public let sourceKey: String
    public let idKey: String
    public let valueKey: String
    public let label: String
    public let kind: UsageMetricKind
    public let unitKey: String?
    public let secondary: Bool

    public init(
        sourceKey: String,
        idKey: String,
        valueKey: String,
        label: String,
        kind: UsageMetricKind,
        unitKey: String?,
        secondary: Bool
    ) {
        self.sourceKey = sourceKey
        self.idKey = idKey
        self.valueKey = valueKey
        self.label = label
        self.kind = kind
        self.unitKey = unitKey
        self.secondary = secondary
    }
}

/// The provider's oauth block the app needs at runtime: the refresh grant AND
/// (for on-device sign-in) the authorization-code mint. The desktop-only
/// loopback port is deliberately not mirrored — iOS uses the out-of-band
/// `manualRedirectUri`.
public struct OAuthEndpoint: Sendable, Equatable {
    public let authorizeUrl: URL
    public let tokenUrl: URL
    public let clientId: String
    public let scopes: [String]
    /// Out-of-band redirect that displays the code for the user to paste — the
    /// mobile-friendly lane (no localhost server, no custom-scheme allowlisting).
    public let manualRedirectUri: String
    /// Device-authorization-grant endpoints (OpenAI Codex): request a user code,
    /// then poll for tokens. nil for providers that use the auth-code flow.
    public let deviceCodeUrl: URL?
    public let deviceTokenUrl: URL?

    public init(
        authorizeUrl: URL,
        tokenUrl: URL,
        clientId: String,
        scopes: [String],
        manualRedirectUri: String,
        deviceCodeUrl: URL? = nil,
        deviceTokenUrl: URL? = nil
    ) {
        self.authorizeUrl = authorizeUrl
        self.tokenUrl = tokenUrl
        self.clientId = clientId
        self.scopes = scopes
        self.manualRedirectUri = manualRedirectUri
        self.deviceCodeUrl = deviceCodeUrl
        self.deviceTokenUrl = deviceTokenUrl
    }
}

/// A query parameter: a literal, or a value computed client-side at request
/// time from a small closed vocabulary (billing APIs need time ranges).
public enum QueryParam: Sendable, Equatable {
    case value(String)
    case monthStartUnixSeconds
    case currentYear
    case currentMonth
}

public struct ProviderSpec: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let auth: String
    /// Community-proven but undocumented endpoint: surfaced in UI and docs.
    public let experimental: Bool
    public let usageMethod: String
    /// May contain "{account_id}" (GitHub usernames, xAI team ids) — a
    /// String template because URL(string:) percent-encodes the braces.
    public let usageURLTemplate: String
    /// Header templates; "{access_token}" / "{account_id}" substituted at request time.
    public let headers: [String: String]
    public let query: [(name: String, param: QueryParam)]
    public let poll: PollPolicy
    public let responseFields: ResponseFields?
    public let planKey: String?
    public let additionalWindows: AdditionalWindows?
    public let windows: [WindowMapping]
    public let metricMappings: [MetricMapping]
    public let metricCollectionMappings: [MetricCollectionMapping]
    public let manualEntryHint: String?
    /// Non-nil only for providers whose refresh grant is verified (Claude).
    public let oauth: OAuthEndpoint?

    public init(
        id: String,
        displayName: String,
        auth: String = "oauth_bearer",
        experimental: Bool = false,
        usageMethod: String,
        usageURL: String,
        headers: [String: String],
        query: [(name: String, param: QueryParam)] = [],
        poll: PollPolicy,
        responseFields: ResponseFields? = nil,
        planKey: String?,
        additionalWindows: AdditionalWindows?,
        windows: [WindowMapping],
        metricMappings: [MetricMapping] = [],
        metricCollectionMappings: [MetricCollectionMapping] = [],
        manualEntryHint: String? = nil,
        oauth: OAuthEndpoint? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.auth = auth
        self.experimental = experimental
        self.usageMethod = usageMethod
        self.usageURLTemplate = usageURL
        self.headers = headers
        self.query = query
        self.poll = poll
        self.responseFields = responseFields
        self.planKey = planKey
        self.additionalWindows = additionalWindows
        self.windows = windows
        self.metricMappings = metricMappings
        self.metricCollectionMappings = metricCollectionMappings
        self.manualEntryHint = manualEntryHint
        self.oauth = oauth
    }

    public static func == (lhs: ProviderSpec, rhs: ProviderSpec) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.auth == rhs.auth
            && lhs.experimental == rhs.experimental
            && lhs.usageMethod == rhs.usageMethod
            && lhs.usageURLTemplate == rhs.usageURLTemplate
            && lhs.headers == rhs.headers
            && lhs.query.count == rhs.query.count
            && zip(lhs.query, rhs.query).allSatisfy { $0.name == $1.name && $0.param == $1.param }
            && lhs.poll == rhs.poll
            && lhs.responseFields == rhs.responseFields
            && lhs.planKey == rhs.planKey
            && lhs.additionalWindows == rhs.additionalWindows
            && lhs.windows == rhs.windows
            && lhs.metricMappings == rhs.metricMappings
            && lhs.metricCollectionMappings == rhs.metricCollectionMappings
            && lhs.manualEntryHint == rhs.manualEntryHint
            && lhs.oauth == rhs.oauth
    }
}

/// Hand-mirrored from protocol/providers.json for runtime independence.
/// SpecParityTests asserts these constants match the JSON — drift fails CI.
public enum ProviderRegistry {
    public static let claude = ProviderSpec(
        id: "claude",
        displayName: "Claude",
        usageMethod: "GET",
        usageURL: "https://api.anthropic.com/api/oauth/usage",
        headers: [
            "Authorization": "Bearer {access_token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-code/2.1.32",
        ],
        poll: PollPolicy(minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
        responseFields: ResponseFields(utilization: "utilization", resetsAt: "resets_at", windowSeconds: nil),
        planKey: nil,
        additionalWindows: AdditionalWindows(
            sourceKey: "limits",
            idKey: "scope.model.display_name",
            secondary: true,
            filter: AdditionalWindowFilter(key: "kind", equals: "weekly_scoped"),
            resetFormat: .iso8601,
            idPrefix: "weekly_scoped",
            labelKey: "scope.model.display_name",
            windowSeconds: 604_800,
            // limits[] entries carry `percent`, NOT the top-level
            // `utilization` key — verified against the live endpoint
            // 2026-07-21. Without this override every model-scoped window is
            // silently dropped, which is why the Models tab was empty while
            // session and weekly mapped fine.
            fields: WindowFieldOverride(utilization: "percent", resetsAt: "resets_at")
        ),
        windows: [
            WindowMapping(id: "session", sourceKey: "five_hour", resetFormat: .iso8601, windowSeconds: 18000, secondary: false),
            WindowMapping(id: "weekly", sourceKey: "seven_day", resetFormat: .iso8601, windowSeconds: 604_800, secondary: false),
            WindowMapping(id: "weekly_sonnet", sourceKey: "seven_day_sonnet", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
            WindowMapping(id: "weekly_opus", sourceKey: "seven_day_opus", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
            WindowMapping(id: "weekly_oauth_apps", sourceKey: "seven_day_oauth_apps", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
            WindowMapping(id: "weekly_cowork", sourceKey: "seven_day_cowork", resetFormat: .iso8601, windowSeconds: 604_800, secondary: true),
        ],
        metricMappings: [
            MetricMapping(id: "extra_used", label: "Extra usage (month)", sourceKey: "extra_usage.used_credits", kind: .spend, unit: "USD", secondary: false, unitKey: "extra_usage.currency"),
            MetricMapping(id: "extra_limit", label: "Extra usage limit", sourceKey: "extra_usage.monthly_limit", kind: .limit, unit: "USD", secondary: true, unitKey: "extra_usage.currency"),
        ],
        manualEntryHint: "Paste a Claude access token, or on Mac use Import from this Mac (~/.claude/.credentials.json). Manual tokens do not auto-renew.",
        oauth: OAuthEndpoint(
            authorizeUrl: URL(string: "https://claude.ai/oauth/authorize")!,
            tokenUrl: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            clientId: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            scopes: ["org:create_api_key", "user:profile", "user:inference"],
            manualRedirectUri: "https://console.anthropic.com/oauth/code/callback"
        )
    )

    public static let codex = ProviderSpec(
        id: "codex",
        displayName: "ChatGPT / Codex",
        usageMethod: "GET",
        usageURL: "https://chatgpt.com/backend-api/wham/usage",
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
        ],
        manualEntryHint: "Paste tokens.access_token and tokens.account_id from ~/.codex/auth.json, or on Mac use Import from this Mac. Manual tokens do not auto-renew.",
        oauth: OAuthEndpoint(
            authorizeUrl: URL(string: "https://auth.openai.com/oauth/authorize")!,
            tokenUrl: URL(string: "https://auth.openai.com/oauth/token")!,
            clientId: "app_EMoamEEZ73f0CkXaXp7hrann",
            scopes: ["openid", "profile", "email", "offline_access", "api.connectors.read", "api.connectors.invoke"],
            manualRedirectUri: "https://auth.openai.com/deviceauth/callback",
            deviceCodeUrl: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!,
            deviceTokenUrl: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
        )
    )

    public static let openRouter = ProviderSpec(
        id: "openrouter",
        displayName: "OpenRouter",
        auth: "api_key_bearer",
        usageMethod: "GET",
        usageURL: "https://openrouter.ai/api/v1/key",
        headers: [
            "Authorization": "Bearer {access_token}",
            "Accept": "application/json",
            "User-Agent": "Vigil/0.10",
        ],
        poll: PollPolicy(minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "usage", label: "Credits used", sourceKey: "data.usage", kind: .spend, unit: "USD", secondary: false),
            MetricMapping(id: "limit", label: "Credit limit", sourceKey: "data.limit", kind: .limit, unit: "USD", secondary: true),
            MetricMapping(id: "remaining", label: "Credits remaining", sourceKey: "data.limit_remaining", kind: .remaining, unit: "USD", secondary: false),
        ],
        manualEntryHint: "Create or copy an OpenRouter API key from openrouter.ai → Keys and paste it here."
    )

    public static let deepSeek = ProviderSpec(
        id: "deepseek",
        displayName: "DeepSeek",
        auth: "api_key_bearer",
        usageMethod: "GET",
        usageURL: "https://api.deepseek.com/user/balance",
        headers: [
            "Authorization": "Bearer {access_token}",
            "Accept": "application/json",
            "User-Agent": "Vigil/0.10",
        ],
        poll: PollPolicy(minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600),
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricCollectionMappings: [
            MetricCollectionMapping(
                sourceKey: "balance_infos",
                idKey: "currency",
                valueKey: "total_balance",
                label: "Balance",
                kind: .balance,
                unitKey: "currency",
                secondary: false
            ),
        ],
        manualEntryHint: "Create or copy a DeepSeek API key from platform.deepseek.com → API Keys and paste it here."
    )

    private static let standardPoll = PollPolicy(
        minSeconds: 300, jitterSeconds: 60, backoff429BaseSeconds: 900, backoffMaxSeconds: 3600
    )

    private static func gatewayHeaders() -> [String: String] {
        [
            "Authorization": "Bearer {access_token}",
            "Accept": "application/json",
            "User-Agent": "Vigil/0.10",
        ]
    }

    private static func moonshotSpec(id: String, name: String, url: String, unit: String, hint: String) -> ProviderSpec {
        ProviderSpec(
            id: id,
            displayName: name,
            auth: "api_key_bearer",
            usageMethod: "GET",
            usageURL: url,
            headers: gatewayHeaders(),
            poll: standardPoll,
            planKey: nil,
            additionalWindows: nil,
            windows: [],
            metricMappings: [
                MetricMapping(id: "balance", label: "Balance", sourceKey: "data.available_balance", kind: .balance, unit: unit, secondary: false),
                MetricMapping(id: "balance_cash", label: "Cash balance", sourceKey: "data.cash_balance", kind: .balance, unit: unit, secondary: true),
                MetricMapping(id: "balance_voucher", label: "Voucher balance", sourceKey: "data.voucher_balance", kind: .balance, unit: unit, secondary: true),
            ],
            manualEntryHint: hint
        )
    }

    public static let moonshot = moonshotSpec(
        id: "moonshot",
        name: "Moonshot (Kimi)",
        url: "https://api.moonshot.ai/v1/users/me/balance",
        unit: "USD",
        hint: "Paste your Moonshot open-platform API key (sk-...) from platform.kimi.ai -> Console -> API Keys. China-platform keys need the Moonshot China provider."
    )

    public static let moonshotCN = moonshotSpec(
        id: "moonshot_cn",
        name: "Moonshot (Kimi) China",
        url: "https://api.moonshot.cn/v1/users/me/balance",
        unit: "CNY",
        hint: "Paste your Moonshot China open-platform API key from platform.moonshot.cn -> Console -> API Keys."
    )

    private static func minimaxSpec(id: String, name: String, url: String, hint: String) -> ProviderSpec {
        ProviderSpec(
            id: id,
            displayName: name,
            auth: "api_key_bearer",
            usageMethod: "GET",
            usageURL: url,
            headers: gatewayHeaders(),
            poll: standardPoll,
            responseFields: ResponseFields(
                utilization: "current_interval_remaining_percent",
                resetsAt: "end_time",
                windowSeconds: nil,
                utilizationKind: .remaining,
                allowStringNumbers: true
            ),
            planKey: nil,
            additionalWindows: nil,
            windows: [
                WindowMapping(id: "session", sourceKey: "data.model_remains[model_name=general]", resetFormat: .unixMillis, windowSeconds: nil, secondary: false),
                WindowMapping(
                    id: "weekly",
                    sourceKey: "data.model_remains[model_name=general]",
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: false,
                    fields: WindowFieldOverride(utilization: "current_weekly_remaining_percent", resetsAt: "weekly_end_time")
                ),
                WindowMapping(id: "session_video", sourceKey: "data.model_remains[model_name=video]", resetFormat: .unixMillis, windowSeconds: nil, secondary: true),
                WindowMapping(
                    id: "weekly_video",
                    sourceKey: "data.model_remains[model_name=video]",
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: true,
                    fields: WindowFieldOverride(utilization: "current_weekly_remaining_percent", resetsAt: "weekly_end_time")
                ),
            ],
            manualEntryHint: hint
        )
    }

    public static let miniMax = minimaxSpec(
        id: "minimax",
        name: "MiniMax Coding Plan",
        url: "https://api.minimax.io/v1/token_plan/remains",
        hint: "Paste your MiniMax Coding Plan API key (sk-cp-...) from platform.minimax.io -> User Center -> Interface Key. China keys need the MiniMax China provider."
    )

    public static let miniMaxCN = minimaxSpec(
        id: "minimax_cn",
        name: "MiniMax Coding Plan China",
        url: "https://api.minimaxi.com/v1/token_plan/remains",
        hint: "Paste your MiniMax China Coding Plan API key from platform.minimaxi.com -> User Center -> Interface Key."
    )

    public static let openAI = ProviderSpec(
        id: "openai",
        displayName: "OpenAI API",
        auth: "api_key_bearer",
        usageMethod: "GET",
        usageURL: "https://api.openai.com/v1/organization/costs",
        headers: gatewayHeaders(),
        query: [
            (name: "start_time", param: .monthStartUnixSeconds),
            (name: "bucket_width", param: .value("1d")),
            (name: "limit", param: .value("31")),
        ],
        poll: standardPoll,
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "spend_month", label: "Spend (month to date)", sourceKey: "data[].results[].amount.value", kind: .spend, unit: "USD", secondary: false, aggregate: .sum),
        ],
        manualEntryHint: "Create a read-only Admin API key at platform.openai.com -> Settings -> Organization -> Admin keys and paste it. Regular project keys (sk-proj-...) are rejected by the billing endpoint."
    )

    public static let gitHub = ProviderSpec(
        id: "github",
        displayName: "GitHub Copilot",
        auth: "api_key_bearer",
        usageMethod: "GET",
        usageURL: "https://api.github.com/users/{account_id}/settings/billing/ai_credit/usage",
        headers: [
            "Authorization": "Bearer {access_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Vigil/0.10",
        ],
        query: [
            (name: "year", param: .currentYear),
            (name: "month", param: .currentMonth),
        ],
        poll: standardPoll,
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "spend_month", label: "AI spend (month)", sourceKey: "usageItems[].netAmount", kind: .spend, unit: "USD", secondary: false, aggregate: .sum),
            MetricMapping(id: "credits_used", label: "Credits used (month)", sourceKey: "usageItems[].netQuantity", kind: .spend, unit: "credits", secondary: true, aggregate: .sum),
        ],
        manualEntryHint: "Create a fine-grained token at github.com -> Settings -> Developer settings with Account -> Plan (read) permission, and enter it together with your GitHub username. Org-managed Copilot seats report empty usage."
    )

    public static let xAI = ProviderSpec(
        id: "xai",
        displayName: "xAI API",
        auth: "api_key_bearer",
        experimental: true,
        usageMethod: "GET",
        usageURL: "https://management-api.x.ai/v1/billing/teams/{account_id}/prepaid/balance",
        headers: gatewayHeaders(),
        poll: standardPoll,
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "balance", label: "Prepaid balance", sourceKey: "total.val", kind: .balance, unit: "USD", secondary: false),
        ],
        manualEntryHint: "Create a Management Key at console.x.ai -> Settings -> Management Keys and enter it with your team ID (visible in console URLs). Experimental: the balance denomination has not been verified against a live account."
    )

    public static let zAI = ProviderSpec(
        id: "zai",
        displayName: "Z.ai Coding Plan",
        auth: "api_key_bearer",
        experimental: true,
        usageMethod: "GET",
        usageURL: "https://api.z.ai/api/monitor/usage/quota/limit",
        headers: gatewayHeaders(),
        poll: standardPoll,
        responseFields: ResponseFields(utilization: "percentage", resetsAt: "nextResetTime", windowSeconds: nil),
        planKey: "data.level",
        additionalWindows: nil,
        windows: [
            WindowMapping(id: "session", sourceKey: "data.limits[type=TOKENS_LIMIT]", resetFormat: .unixSeconds, windowSeconds: nil, secondary: false),
            WindowMapping(id: "monthly", sourceKey: "data.limits[type=TIME_LIMIT]", resetFormat: .unixSeconds, windowSeconds: nil, secondary: true),
        ],
        manualEntryHint: "Paste your GLM Coding Plan API key from z.ai -> Manage API Key. Experimental: the quota endpoint is undocumented and its schema may drift."
    )

    public static let cursor = ProviderSpec(
        id: "cursor",
        displayName: "Cursor",
        auth: "web_session_cookie",
        experimental: true,
        usageMethod: "GET",
        usageURL: "https://cursor.com/api/usage-summary",
        headers: [
            "Cookie": "WorkosCursorSessionToken={access_token}",
            "Accept": "application/json",
            "Referer": "https://www.cursor.com/settings",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        ],
        poll: standardPoll,
        responseFields: ResponseFields(utilization: "plan.totalPercentUsed", resetsAt: "billingCycleEnd", windowSeconds: nil),
        planKey: "membershipType",
        additionalWindows: nil,
        windows: [
            WindowMapping(id: "plan", sourceKey: "individualUsage", resetFormat: .unixMillis, windowSeconds: nil, secondary: false),
        ],
        metricMappings: [
            MetricMapping(id: "spend_ondemand", label: "On-demand spend", sourceKey: "individualUsage.onDemand", kind: .spend, unit: "USD", secondary: true, scale: 0.01),
        ],
        manualEntryHint: "On cursor.com while signed in, open DevTools -> Application -> Cookies, copy the WorkosCursorSessionToken value, and paste it here. Experimental: undocumented web API; re-paste when the session expires."
    )

    public static let kimiCode = ProviderSpec(
        id: "kimi_code",
        displayName: "Kimi K3",
        auth: "api_key_bearer",
        experimental: true,
        usageMethod: "GET",
        usageURL: "https://api.kimi.com/coding/v1/usages",
        headers: gatewayHeaders(),
        poll: standardPoll,
        responseFields: ResponseFields(
            utilization: "used_percent",
            resetsAt: "reset_at",
            windowSeconds: nil,
            utilizationKind: .used,
            allowStringNumbers: true
        ),
        planKey: nil,
        additionalWindows: nil,
        windows: [
            WindowMapping(id: "session", sourceKey: "limits[type=session]", resetFormat: .unixSeconds, windowSeconds: 18000, secondary: false),
            WindowMapping(id: "weekly", sourceKey: "usage", resetFormat: .unixSeconds, windowSeconds: 604_800, secondary: false),
        ],
        manualEntryHint: "Paste your Kimi Code API key (KIMI_CODE_API_KEY) — the coding-plan key from platform.kimi.ai, separate from the Moonshot balance key."
    )

    public static let all: [ProviderSpec] = [
        claude, codex, openRouter, deepSeek,
        moonshot, moonshotCN, miniMax, miniMaxCN,
        openAI, gitHub, xAI, zAI, cursor, kimiCode,
    ]

    public static func spec(for id: String) -> ProviderSpec? {
        all.first { $0.id == id }
    }
}
