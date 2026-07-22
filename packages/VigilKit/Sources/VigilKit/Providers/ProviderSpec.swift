import Foundation

public enum ResetFormat: String, Sendable, Equatable {
    case iso8601
    case unixSeconds
    case unixMillis
}

public enum WindowSourceContainer: String, Sendable, Equatable {
    case object
    case array
}

/// Per-window override of the provider's responseFields (e.g. MiniMax keeps
/// session and weekly numbers under different keys of one bucket).
public struct WindowFieldOverride: Sendable, Equatable {
    public let utilization: String?
    public let resetsAt: String
    public let used: String?
    public let limit: String?

    public init(
        utilization: String? = nil,
        resetsAt: String,
        used: String? = nil,
        limit: String? = nil
    ) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.used = used
        self.limit = limit
    }
}

/// A narrow, JSON-friendly equality predicate used to select or suppress a
/// quota bucket. Numeric and boolean response values compare through their
/// JSON string form (for example `3` and `true`).
public struct FieldCondition: Sendable, Equatable {
    public let key: String
    public let equals: String
    public let valueType: String?
    public let allowedNonMatches: [String]

    public init(
        key: String,
        equals: String,
        valueType: String? = nil,
        allowedNonMatches: [String] = []
    ) {
        self.key = key
        self.equals = equals
        self.valueType = valueType
        self.allowedNonMatches = allowedNonMatches
    }
}

/// Converts a provider `(unit, number)` pair into seconds. Optional bounds let
/// one array hold session and weekly entries without pinning the contract to a
/// single exact duration.
public struct WindowDuration: Sendable, Equatable {
    public let unitKey: String
    public let numberKey: String
    public let unitSeconds: [String: Int]
    public let allowedSeconds: [Int]
    public let minimumSeconds: Int?
    public let maximumSecondsExclusive: Int?

    public init(
        unitKey: String,
        numberKey: String,
        unitSeconds: [String: Int],
        allowedSeconds: [Int] = [],
        minimumSeconds: Int? = nil,
        maximumSecondsExclusive: Int? = nil
    ) {
        self.unitKey = unitKey
        self.numberKey = numberKey
        self.unitSeconds = unitSeconds
        self.allowedSeconds = allowedSeconds
        self.minimumSeconds = minimumSeconds
        self.maximumSecondsExclusive = maximumSecondsExclusive
    }
}

public struct WindowMapping: Sendable, Equatable {
    public let id: String
    public let sourceKey: String
    public let sourceKeys: [String]
    public let sourceContainer: WindowSourceContainer
    public let resetFormat: ResetFormat
    public let windowSeconds: Int?
    public let secondary: Bool
    public let conditions: [FieldCondition]
    public let anyConditions: [FieldCondition]
    public let identityAliases: [String]
    public let omitWhen: [FieldCondition]
    public let idByWindowSeconds: [Int: String]
    public let duration: WindowDuration?
    public let label: String?
    public let fields: WindowFieldOverride?
    public let requiredWhenPresent: Bool
    public let fallbackGroup: String?

    public init(
        id: String,
        sourceKey: String,
        sourceKeys: [String] = [],
        sourceContainer: WindowSourceContainer = .object,
        resetFormat: ResetFormat,
        windowSeconds: Int?,
        secondary: Bool,
        conditions: [FieldCondition] = [],
        anyConditions: [FieldCondition] = [],
        identityAliases: [String] = [],
        omitWhen: [FieldCondition] = [],
        idByWindowSeconds: [Int: String] = [:],
        duration: WindowDuration? = nil,
        label: String? = nil,
        fields: WindowFieldOverride? = nil,
        requiredWhenPresent: Bool = true,
        fallbackGroup: String? = nil
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.sourceKeys = sourceKeys
        self.sourceContainer = sourceContainer
        self.resetFormat = resetFormat
        self.windowSeconds = windowSeconds
        self.secondary = secondary
        self.conditions = conditions
        self.anyConditions = anyConditions
        self.identityAliases = identityAliases
        self.omitWhen = omitWhen
        self.idByWindowSeconds = idByWindowSeconds
        self.duration = duration
        self.label = label
        self.fields = fields
        self.requiredWhenPresent = requiredWhenPresent
        self.fallbackGroup = fallbackGroup
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
    public let idFormat: String?
    public let secondary: Bool
    public let filter: AdditionalWindowFilter?
    public let resetFormat: ResetFormat
    /// When set, the id is `${idPrefix}_${normalized(idKey value)}`; absent
    /// means the raw idKey value is the id (Codex lanes).
    public let idPrefix: String?
    public let labelKey: String?
    public let windowSeconds: Int?
    public let fields: WindowFieldOverride?
    /// When enabled, wrong-shaped sources and eligible-but-unmappable entries
    /// mark the response incomplete. Filtered arrays may have zero matches.
    public let requiredWhenPresent: Bool
    public let conditions: [FieldCondition]
    public let entryWindows: [AdditionalEntryWindow]

    public init(
        sourceKey: String,
        idKey: String,
        idFormat: String? = nil,
        secondary: Bool,
        filter: AdditionalWindowFilter? = nil,
        resetFormat: ResetFormat = .unixSeconds,
        idPrefix: String? = nil,
        labelKey: String? = nil,
        windowSeconds: Int? = nil,
        fields: WindowFieldOverride? = nil,
        requiredWhenPresent: Bool = false,
        conditions: [FieldCondition] = [],
        entryWindows: [AdditionalEntryWindow] = []
    ) {
        self.sourceKey = sourceKey
        self.idKey = idKey
        self.idFormat = idFormat
        self.secondary = secondary
        self.filter = filter
        self.resetFormat = resetFormat
        self.idPrefix = idPrefix
        self.labelKey = labelKey
        self.windowSeconds = windowSeconds
        self.fields = fields
        self.requiredWhenPresent = requiredWhenPresent
        self.conditions = conditions
        self.entryWindows = entryWindows
    }
}

public struct AdditionalEntryWindow: Sendable, Equatable {
    public let sourceKey: String
    public let sourceContainer: WindowSourceContainer
    public let idSuffix: String
    public let idSuffixByWindowSeconds: [Int: String]
    public let labelSuffix: String?
    public let labelSuffixByWindowSeconds: [Int: String]
    public let resetFormat: ResetFormat
    public let windowSeconds: Int?
    public let secondary: Bool?
    public let fields: WindowFieldOverride?

    public init(
        sourceKey: String,
        sourceContainer: WindowSourceContainer = .object,
        idSuffix: String,
        idSuffixByWindowSeconds: [Int: String] = [:],
        labelSuffix: String? = nil,
        labelSuffixByWindowSeconds: [Int: String] = [:],
        resetFormat: ResetFormat = .unixSeconds,
        windowSeconds: Int? = nil,
        secondary: Bool? = nil,
        fields: WindowFieldOverride? = nil
    ) {
        self.sourceKey = sourceKey
        self.sourceContainer = sourceContainer
        self.idSuffix = idSuffix
        self.idSuffixByWindowSeconds = idSuffixByWindowSeconds
        self.labelSuffix = labelSuffix
        self.labelSuffixByWindowSeconds = labelSuffixByWindowSeconds
        self.resetFormat = resetFormat
        self.windowSeconds = windowSeconds
        self.secondary = secondary
        self.fields = fields
    }
}

/// Provider-defined status carried inside an HTTP 2xx body.
public struct ResponseEnvelope: Sendable, Equatable {
    public let codeKey: String
    public let okCode: String
    public let codeValueType: String?
    public let successKey: String?
    public let successValue: String
    public let successValueType: String?
    public let authCodes: [String]

    public init(
        codeKey: String,
        okCode: String,
        codeValueType: String? = nil,
        successKey: String? = nil,
        successValue: String = "true",
        successValueType: String? = nil,
        authCodes: [String] = []
    ) {
        self.codeKey = codeKey
        self.okCode = okCode
        self.codeValueType = codeValueType
        self.successKey = successKey
        self.successValue = successValue
        self.successValueType = successValueType
        self.authCodes = authCodes
    }
}

public struct RequiredOutputs: Sendable, Equatable {
    public let minimumWindows: Int?
    public let minimumPrimaryWindows: Int
    public let windowIDs: [String]
    public let minimumMetrics: Int
    public let metricIDs: [String]

    public init(
        minimumWindows: Int? = nil,
        minimumPrimaryWindows: Int = 0,
        windowIDs: [String] = [],
        minimumMetrics: Int = 0,
        metricIDs: [String] = []
    ) {
        self.minimumWindows = minimumWindows
        self.minimumPrimaryWindows = minimumPrimaryWindows
        self.windowIDs = windowIDs
        self.minimumMetrics = minimumMetrics
        self.metricIDs = metricIDs
    }
}

/// Describes a provider response that legitimately carries no finite quota
/// windows. Every entry in the first non-empty source array must match every
/// condition, so malformed or merely empty payloads still report schema drift.
public struct RecognizedEmpty: Sendable, Equatable {
    public let sourceKeys: [String]
    public let allEntriesMatch: [FieldCondition]

    public init(sourceKeys: [String], allEntriesMatch: [FieldCondition]) {
        self.sourceKeys = sourceKeys
        self.allEntriesMatch = allEntriesMatch
    }
}

public struct ExhaustiveCollection: Sendable, Equatable {
    public let sourceKeys: [String]
    public let identityKeys: [String]
    public let allowedIdentities: [String]
    public let uniqueIdentities: [String]
    public let durationIdentities: [String]
    public let duration: WindowDuration?

    public init(
        sourceKeys: [String],
        identityKeys: [String],
        allowedIdentities: [String],
        uniqueIdentities: [String] = [],
        durationIdentities: [String] = [],
        duration: WindowDuration? = nil
    ) {
        self.sourceKeys = sourceKeys
        self.identityKeys = identityKeys
        self.allowedIdentities = allowedIdentities
        self.uniqueIdentities = uniqueIdentities
        self.durationIdentities = durationIdentities
        self.duration = duration
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
    public let conditions: [FieldCondition]
    public let kind: UsageMetricKind
    public let unit: String?
    /// Dot-path to a unit/currency string in the response; overrides `unit`
    /// when it resolves (e.g. Claude extra_usage.currency).
    public let unitKey: String?
    public let requires: [String]
    public let requiresPresent: [String]
    public let equalFields: [[String]]
    public let presencePaths: [String]
    public let requiresPositive: [String]
    public let incompleteWhenAnyRequiredPresent: Bool
    public let fallbackBlockedBy: [String]
    public let secondary: Bool
    public let aggregate: MetricAggregate?
    public let aggregateUnitKey: String?
    public let aggregateExpectedUnit: String?
    /// Multiplier applied after resolution (0.01 converts cents to dollars).
    public let scale: Double?
    public let exponentKey: String?

    public init(
        id: String,
        label: String,
        sourceKey: String,
        kind: UsageMetricKind,
        unit: String?,
        secondary: Bool,
        conditions: [FieldCondition] = [],
        unitKey: String? = nil,
        requires: [String] = [],
        requiresPresent: [String] = [],
        equalFields: [[String]] = [],
        presencePaths: [String] = [],
        requiresPositive: [String] = [],
        incompleteWhenAnyRequiredPresent: Bool = false,
        fallbackBlockedBy: [String] = [],
        aggregate: MetricAggregate? = nil,
        aggregateUnitKey: String? = nil,
        aggregateExpectedUnit: String? = nil,
        scale: Double? = nil,
        exponentKey: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sourceKey = sourceKey
        self.conditions = conditions
        self.kind = kind
        self.unit = unit
        self.unitKey = unitKey
        self.requires = requires
        self.requiresPresent = requiresPresent
        self.equalFields = equalFields
        self.presencePaths = presencePaths
        self.requiresPositive = requiresPositive
        self.incompleteWhenAnyRequiredPresent = incompleteWhenAnyRequiredPresent
        self.fallbackBlockedBy = fallbackBlockedBy
        self.secondary = secondary
        self.aggregate = aggregate
        self.aggregateUnitKey = aggregateUnitKey
        self.aggregateExpectedUnit = aggregateExpectedUnit
        self.scale = scale
        self.exponentKey = exponentKey
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
    /// No stable vendor contract or Vigil production capture: surfaced in UI
    /// and docs so research-derived mapping is never presented as live proof.
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
    public let responseEnvelope: ResponseEnvelope?
    public let requiredOutputs: RequiredOutputs?
    public let recognizedEmpty: RecognizedEmpty?
    public let exhaustiveCollections: [ExhaustiveCollection]
    public let incompleteWhen: [FieldCondition]
    public let requiredConditions: [FieldCondition]
    public let requiredPaths: [String]
    public let absentOrNullPaths: [String]
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
        responseEnvelope: ResponseEnvelope? = nil,
        requiredOutputs: RequiredOutputs? = nil,
        recognizedEmpty: RecognizedEmpty? = nil,
        exhaustiveCollections: [ExhaustiveCollection] = [],
        incompleteWhen: [FieldCondition] = [],
        requiredConditions: [FieldCondition] = [],
        requiredPaths: [String] = [],
        absentOrNullPaths: [String] = [],
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
        self.responseEnvelope = responseEnvelope
        self.requiredOutputs = requiredOutputs
        self.recognizedEmpty = recognizedEmpty
        self.exhaustiveCollections = exhaustiveCollections
        self.incompleteWhen = incompleteWhen
        self.requiredConditions = requiredConditions
        self.requiredPaths = requiredPaths
        self.absentOrNullPaths = absentOrNullPaths
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
            && lhs.responseEnvelope == rhs.responseEnvelope
            && lhs.requiredOutputs == rhs.requiredOutputs
            && lhs.recognizedEmpty == rhs.recognizedEmpty
            && lhs.exhaustiveCollections == rhs.exhaustiveCollections
            && lhs.incompleteWhen == rhs.incompleteWhen
            && lhs.requiredConditions == rhs.requiredConditions
            && lhs.requiredPaths == rhs.requiredPaths
            && lhs.absentOrNullPaths == rhs.absentOrNullPaths
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
        requiredOutputs: RequiredOutputs(minimumWindows: 1, minimumPrimaryWindows: 1),
        requiredPaths: ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"],
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
            fields: WindowFieldOverride(utilization: "percent", resetsAt: "resets_at"),
            requiredWhenPresent: true,
            conditions: [FieldCondition(
                key: "is_active",
                equals: "true",
                valueType: "boolean",
                allowedNonMatches: ["false"]
            )]
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
            MetricMapping(id: "extra_used", label: "Extra usage (month)", sourceKey: "spend.used.amount_minor", kind: .spend, unit: "USD", secondary: false, conditions: [FieldCondition(key: "spend.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], unitKey: "spend.used.currency", requires: ["spend.used.amount_minor", "spend.limit.amount_minor", "spend.used.exponent", "spend.limit.exponent"], requiresPresent: ["spend.used.currency", "spend.limit.currency"], equalFields: [["spend.used.currency", "spend.limit.currency"], ["spend.used.exponent", "spend.limit.exponent"]], presencePaths: ["spend"], incompleteWhenAnyRequiredPresent: true, scale: 0.01, exponentKey: "spend.used.exponent"),
            MetricMapping(id: "extra_limit", label: "Extra usage limit", sourceKey: "spend.limit.amount_minor", kind: .limit, unit: "USD", secondary: true, conditions: [FieldCondition(key: "spend.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], unitKey: "spend.limit.currency", requires: ["spend.used.amount_minor", "spend.limit.amount_minor", "spend.used.exponent", "spend.limit.exponent"], requiresPresent: ["spend.used.currency", "spend.limit.currency"], equalFields: [["spend.used.currency", "spend.limit.currency"], ["spend.used.exponent", "spend.limit.exponent"]], presencePaths: ["spend"], incompleteWhenAnyRequiredPresent: true, scale: 0.01, exponentKey: "spend.limit.exponent"),
            MetricMapping(id: "extra_used", label: "Extra usage (month)", sourceKey: "extra_usage.used_credits", kind: .spend, unit: "USD", secondary: false, conditions: [FieldCondition(key: "extra_usage.is_enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], unitKey: "extra_usage.currency", requires: ["extra_usage.used_credits", "extra_usage.monthly_limit"], requiresPresent: ["extra_usage.currency"], presencePaths: ["extra_usage"], incompleteWhenAnyRequiredPresent: true, fallbackBlockedBy: ["spend"], scale: 0.01, exponentKey: "extra_usage.decimal_places"),
            MetricMapping(id: "extra_limit", label: "Extra usage limit", sourceKey: "extra_usage.monthly_limit", kind: .limit, unit: "USD", secondary: true, conditions: [FieldCondition(key: "extra_usage.is_enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], unitKey: "extra_usage.currency", requires: ["extra_usage.used_credits", "extra_usage.monthly_limit"], requiresPresent: ["extra_usage.currency"], presencePaths: ["extra_usage"], incompleteWhenAnyRequiredPresent: true, fallbackBlockedBy: ["spend"], scale: 0.01, exponentKey: "extra_usage.decimal_places"),
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
        requiredOutputs: RequiredOutputs(minimumWindows: 1, minimumPrimaryWindows: 1),
        requiredPaths: ["plan_type", "rate_limit.primary_window", "rate_limit.secondary_window"],
        absentOrNullPaths: ["spend_control", "code_review_rate_limit"],
        planKey: "plan_type",
        additionalWindows: AdditionalWindows(
            sourceKey: "additional_rate_limits",
            idKey: "metered_feature",
            idFormat: "asciiSlug",
            secondary: true,
            labelKey: "limit_name",
            requiredWhenPresent: true,
            entryWindows: [
                AdditionalEntryWindow(
                    sourceKey: "rate_limit.primary_window",
                    idSuffix: "primary",
                    idSuffixByWindowSeconds: [18_000: "session", 604_800: "weekly"],
                    labelSuffixByWindowSeconds: [18_000: "5 hours", 604_800: "Weekly"]
                ),
                AdditionalEntryWindow(
                    sourceKey: "rate_limit.secondary_window",
                    idSuffix: "secondary",
                    idSuffixByWindowSeconds: [18_000: "session", 604_800: "weekly"],
                    labelSuffixByWindowSeconds: [18_000: "5 hours", 604_800: "Weekly"]
                ),
            ]
        ),
        windows: [
            WindowMapping(
                id: "session",
                sourceKey: "rate_limit.primary_window",
                resetFormat: .unixSeconds,
                windowSeconds: nil,
                secondary: false,
                idByWindowSeconds: [18_000: "session", 604_800: "weekly"]
            ),
            WindowMapping(
                id: "weekly",
                sourceKey: "rate_limit.secondary_window",
                resetFormat: .unixSeconds,
                windowSeconds: nil,
                secondary: false,
                idByWindowSeconds: [18_000: "session", 604_800: "weekly"]
            ),
        ],
        metricMappings: [
            MetricMapping(id: "credits_balance", label: "Flex credits", sourceKey: "credits.balance", kind: .balance, unit: "credits", secondary: false, conditions: [
                FieldCondition(key: "credits.has_credits", equals: "true", valueType: "boolean", allowedNonMatches: ["false"]),
                FieldCondition(key: "credits.unlimited", equals: "false", valueType: "boolean", allowedNonMatches: ["true"]),
            ], presencePaths: ["credits"]),
            MetricMapping(id: "reset_credits", label: "Reset credits available", sourceKey: "rate_limit_reset_credits.available_count", kind: .remaining, unit: "resets", secondary: true, presencePaths: ["rate_limit_reset_credits"]),
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
        requiredOutputs: RequiredOutputs(
            minimumMetrics: 8,
            metricIDs: [
                "usage_lifetime", "usage_daily", "usage_weekly", "usage_monthly",
                "byok_usage_lifetime", "byok_usage_daily",
                "byok_usage_weekly", "byok_usage_monthly",
            ]
        ),
        requiredPaths: ["data.limit", "data.limit_reset", "data.limit_remaining"],
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "usage_lifetime", label: "Usage (all time)", sourceKey: "data.usage", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "usage_daily", label: "Usage (day)", sourceKey: "data.usage_daily", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "usage_weekly", label: "Usage (week)", sourceKey: "data.usage_weekly", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "usage_monthly", label: "Usage (month)", sourceKey: "data.usage_monthly", kind: .spend, unit: "USD", secondary: false),
            MetricMapping(id: "byok_usage_lifetime", label: "BYOK usage (all time)", sourceKey: "data.byok_usage", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "byok_usage_daily", label: "BYOK usage (day)", sourceKey: "data.byok_usage_daily", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "byok_usage_weekly", label: "BYOK usage (week)", sourceKey: "data.byok_usage_weekly", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "byok_usage_monthly", label: "BYOK usage (month)", sourceKey: "data.byok_usage_monthly", kind: .spend, unit: "USD", secondary: true),
            MetricMapping(id: "limit", label: "Key spending limit", sourceKey: "data.limit", kind: .limit, unit: "USD", secondary: true, requires: ["data.limit", "data.limit_remaining"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "remaining", label: "Key limit remaining", sourceKey: "data.limit_remaining", kind: .remaining, unit: "USD", secondary: false, requires: ["data.limit", "data.limit_remaining"], incompleteWhenAnyRequiredPresent: true),
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
        requiredOutputs: RequiredOutputs(minimumMetrics: 1),
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
            responseEnvelope: ResponseEnvelope(
                codeKey: "code",
                okCode: "0",
                codeValueType: "number",
                successKey: "status",
                successValueType: "boolean"
            ),
            requiredOutputs: RequiredOutputs(
                minimumMetrics: 3,
                metricIDs: ["balance", "balance_cash", "balance_voucher"]
            ),
            requiredConditions: [
                FieldCondition(key: "scode", equals: "0x0", valueType: "string")
            ],
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
        hint: "Paste your Moonshot China open-platform API key from platform.kimi.com (formerly platform.moonshot.cn) -> Console -> API Keys."
    )

    private static func minimaxSpec(id: String, name: String, url: String, hint: String) -> ProviderSpec {
        ProviderSpec(
            id: id,
            displayName: name,
            auth: "api_key_bearer",
            experimental: true,
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
            responseEnvelope: ResponseEnvelope(
                codeKey: "base_resp.status_code",
                okCode: "0",
                codeValueType: "number",
                authCodes: ["1004", "1011", "1024"]
            ),
            requiredOutputs: RequiredOutputs(minimumWindows: 1, minimumPrimaryWindows: 1),
            recognizedEmpty: RecognizedEmpty(
                sourceKeys: ["model_remains", "data.model_remains"],
                allEntriesMatch: [
                    FieldCondition(key: "current_interval_status", equals: "3", valueType: "number"),
                    FieldCondition(key: "current_weekly_status", equals: "3", valueType: "number"),
                ]
            ),
            exhaustiveCollections: [ExhaustiveCollection(
                sourceKeys: ["model_remains", "data.model_remains"],
                identityKeys: ["model_name"],
                allowedIdentities: ["general", "video"],
                uniqueIdentities: ["general", "video"]
            )],
            planKey: nil,
            additionalWindows: nil,
            windows: [
                WindowMapping(
                    id: "session",
                    sourceKey: "model_remains",
                    sourceKeys: ["data.model_remains"],
                    sourceContainer: .array,
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: false,
                    conditions: [FieldCondition(key: "model_name", equals: "general")],
                    omitWhen: [FieldCondition(key: "current_interval_status", equals: "3", valueType: "number", allowedNonMatches: ["1", "2"])]
                ),
                WindowMapping(
                    id: "weekly",
                    sourceKey: "model_remains",
                    sourceKeys: ["data.model_remains"],
                    sourceContainer: .array,
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: false,
                    conditions: [FieldCondition(key: "model_name", equals: "general")],
                    omitWhen: [FieldCondition(key: "current_weekly_status", equals: "3", valueType: "number", allowedNonMatches: ["1", "2"])],
                    fields: WindowFieldOverride(utilization: "current_weekly_remaining_percent", resetsAt: "weekly_end_time")
                ),
                WindowMapping(
                    id: "session_video",
                    sourceKey: "model_remains",
                    sourceKeys: ["data.model_remains"],
                    sourceContainer: .array,
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: true,
                    conditions: [FieldCondition(key: "model_name", equals: "video")],
                    omitWhen: [FieldCondition(key: "current_interval_status", equals: "3", valueType: "number", allowedNonMatches: ["1", "2"])]
                ),
                WindowMapping(
                    id: "weekly_video",
                    sourceKey: "model_remains",
                    sourceKeys: ["data.model_remains"],
                    sourceContainer: .array,
                    resetFormat: .unixMillis,
                    windowSeconds: nil,
                    secondary: true,
                    conditions: [FieldCondition(key: "model_name", equals: "video")],
                    omitWhen: [FieldCondition(key: "current_weekly_status", equals: "3", valueType: "number", allowedNonMatches: ["1", "2"])],
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
        requiredOutputs: RequiredOutputs(minimumMetrics: 1, metricIDs: ["spend_month"]),
        incompleteWhen: [FieldCondition(key: "has_more", equals: "true", valueType: "boolean")],
        requiredConditions: [FieldCondition(key: "has_more", equals: "false", valueType: "boolean")],
        absentOrNullPaths: ["next_page"],
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "spend_month", label: "Spend (month to date)", sourceKey: "data[].results[].amount.value", kind: .spend, unit: "USD", secondary: false, aggregate: .sum, aggregateUnitKey: "data[].results[].amount.currency", aggregateExpectedUnit: "usd"),
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
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "Vigil/0.10",
        ],
        query: [
            (name: "year", param: .currentYear),
            (name: "month", param: .currentMonth),
        ],
        poll: standardPoll,
        requiredOutputs: RequiredOutputs(
            minimumMetrics: 2,
            metricIDs: ["credits_used", "spend_month"]
        ),
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "credits_used", label: "AI credits consumed (month)", sourceKey: "usageItems[].grossQuantity", kind: .spend, unit: "credits", secondary: false, aggregate: .sum),
            MetricMapping(id: "spend_month", label: "Billable AI spend (month)", sourceKey: "usageItems[].netAmount", kind: .spend, unit: "USD", secondary: false, aggregate: .sum),
            MetricMapping(id: "credits_billable", label: "Billable AI credits (month)", sourceKey: "usageItems[].netQuantity", kind: .spend, unit: "credits", secondary: true, aggregate: .sum),
            MetricMapping(id: "credits_included", label: "Included AI credits (month)", sourceKey: "usageItems[].discountQuantity", kind: .spend, unit: "credits", secondary: true, aggregate: .sum),
        ],
        manualEntryHint: "Create a fine-grained token at github.com -> Settings -> Developer settings with Account -> Plan (read) permission, and enter it together with your GitHub username. Org-managed Copilot seats report empty usage."
    )

    public static let xAI = ProviderSpec(
        id: "xai",
        displayName: "xAI API",
        auth: "api_key_bearer",
        usageMethod: "GET",
        usageURL: "https://management-api.x.ai/v1/billing/teams/{account_id}/prepaid/balance",
        headers: gatewayHeaders(),
        poll: standardPoll,
        requiredOutputs: RequiredOutputs(minimumMetrics: 1, metricIDs: ["balance"]),
        planKey: nil,
        additionalWindows: nil,
        windows: [],
        metricMappings: [
            MetricMapping(id: "balance", label: "Prepaid balance", sourceKey: "total.val", kind: .balance, unit: "USD", secondary: false, scale: -0.01),
        ],
        manualEntryHint: "Create a Management Key with billing read access at console.x.ai -> Settings -> Management Keys and enter it with your team ID (visible in console URLs)."
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
        responseEnvelope: ResponseEnvelope(
            codeKey: "code",
            okCode: "200",
            codeValueType: "number",
            successKey: "success",
            successValueType: "boolean",
            authCodes: ["1000", "1001"]
        ),
        requiredOutputs: RequiredOutputs(minimumWindows: 2, windowIDs: ["session", "weekly"]),
        exhaustiveCollections: [ExhaustiveCollection(
            sourceKeys: ["data.limits", "limits"],
            identityKeys: ["type", "name"],
            allowedIdentities: ["TOKENS_LIMIT", "TIME_LIMIT"],
            uniqueIdentities: ["TIME_LIMIT"],
            durationIdentities: ["TOKENS_LIMIT"],
            duration: WindowDuration(
                unitKey: "unit",
                numberKey: "number",
                unitSeconds: ["3": 3_600, "4": 86_400, "5": 2_592_000, "6": 604_800],
                allowedSeconds: [14_400, 18_000, 604_800]
            )
        )],
        planKey: "data.level",
        additionalWindows: nil,
        windows: [
            WindowMapping(
                id: "session",
                sourceKey: "data.limits",
                sourceKeys: ["limits"],
                sourceContainer: .array,
                resetFormat: .unixMillis,
                windowSeconds: nil,
                secondary: false,
                anyConditions: [
                    FieldCondition(key: "type", equals: "TOKENS_LIMIT"),
                    FieldCondition(key: "name", equals: "TOKENS_LIMIT"),
                ],
                identityAliases: ["type", "name"],
                duration: WindowDuration(
                    unitKey: "unit",
                    numberKey: "number",
                    unitSeconds: ["3": 3_600, "4": 86_400, "5": 2_592_000, "6": 604_800],
                    allowedSeconds: [14_400, 18_000]
                ),
                label: "Token usage (session)"
            ),
            WindowMapping(
                id: "weekly",
                sourceKey: "data.limits",
                sourceKeys: ["limits"],
                sourceContainer: .array,
                resetFormat: .unixMillis,
                windowSeconds: nil,
                secondary: false,
                anyConditions: [
                    FieldCondition(key: "type", equals: "TOKENS_LIMIT"),
                    FieldCondition(key: "name", equals: "TOKENS_LIMIT"),
                ],
                identityAliases: ["type", "name"],
                duration: WindowDuration(
                    unitKey: "unit",
                    numberKey: "number",
                    unitSeconds: ["3": 3_600, "4": 86_400, "5": 2_592_000, "6": 604_800],
                    allowedSeconds: [604_800]
                ),
                label: "Token usage (week)"
            ),
        ],
        metricMappings: [
            MetricMapping(id: "websearch_used", label: "Web searches used", sourceKey: "data.limits[type=TIME_LIMIT].currentValue", kind: .spend, unit: "calls", secondary: true, requires: ["data.limits[type=TIME_LIMIT].currentValue", "data.limits[type=TIME_LIMIT].usage", "data.limits[type=TIME_LIMIT].remaining"], presencePaths: ["data.limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_used", label: "Web searches used", sourceKey: "data.limits[name=TIME_LIMIT].currentValue", kind: .spend, unit: "calls", secondary: true, requires: ["data.limits[name=TIME_LIMIT].currentValue", "data.limits[name=TIME_LIMIT].usage", "data.limits[name=TIME_LIMIT].remaining"], presencePaths: ["data.limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_used", label: "Web searches used", sourceKey: "limits[type=TIME_LIMIT].currentValue", kind: .spend, unit: "calls", secondary: true, requires: ["limits[type=TIME_LIMIT].currentValue", "limits[type=TIME_LIMIT].usage", "limits[type=TIME_LIMIT].remaining"], presencePaths: ["limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_used", label: "Web searches used", sourceKey: "limits[name=TIME_LIMIT].currentValue", kind: .spend, unit: "calls", secondary: true, requires: ["limits[name=TIME_LIMIT].currentValue", "limits[name=TIME_LIMIT].usage", "limits[name=TIME_LIMIT].remaining"], presencePaths: ["limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_limit", label: "Web search limit", sourceKey: "data.limits[type=TIME_LIMIT].usage", kind: .limit, unit: "calls", secondary: true, requires: ["data.limits[type=TIME_LIMIT].currentValue", "data.limits[type=TIME_LIMIT].usage", "data.limits[type=TIME_LIMIT].remaining"], presencePaths: ["data.limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_limit", label: "Web search limit", sourceKey: "data.limits[name=TIME_LIMIT].usage", kind: .limit, unit: "calls", secondary: true, requires: ["data.limits[name=TIME_LIMIT].currentValue", "data.limits[name=TIME_LIMIT].usage", "data.limits[name=TIME_LIMIT].remaining"], presencePaths: ["data.limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_limit", label: "Web search limit", sourceKey: "limits[type=TIME_LIMIT].usage", kind: .limit, unit: "calls", secondary: true, requires: ["limits[type=TIME_LIMIT].currentValue", "limits[type=TIME_LIMIT].usage", "limits[type=TIME_LIMIT].remaining"], presencePaths: ["limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_limit", label: "Web search limit", sourceKey: "limits[name=TIME_LIMIT].usage", kind: .limit, unit: "calls", secondary: true, requires: ["limits[name=TIME_LIMIT].currentValue", "limits[name=TIME_LIMIT].usage", "limits[name=TIME_LIMIT].remaining"], presencePaths: ["limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_remaining", label: "Web searches remaining", sourceKey: "data.limits[type=TIME_LIMIT].remaining", kind: .remaining, unit: "calls", secondary: true, requires: ["data.limits[type=TIME_LIMIT].currentValue", "data.limits[type=TIME_LIMIT].usage", "data.limits[type=TIME_LIMIT].remaining"], presencePaths: ["data.limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_remaining", label: "Web searches remaining", sourceKey: "data.limits[name=TIME_LIMIT].remaining", kind: .remaining, unit: "calls", secondary: true, requires: ["data.limits[name=TIME_LIMIT].currentValue", "data.limits[name=TIME_LIMIT].usage", "data.limits[name=TIME_LIMIT].remaining"], presencePaths: ["data.limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_remaining", label: "Web searches remaining", sourceKey: "limits[type=TIME_LIMIT].remaining", kind: .remaining, unit: "calls", secondary: true, requires: ["limits[type=TIME_LIMIT].currentValue", "limits[type=TIME_LIMIT].usage", "limits[type=TIME_LIMIT].remaining"], presencePaths: ["limits[type=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
            MetricMapping(id: "websearch_remaining", label: "Web searches remaining", sourceKey: "limits[name=TIME_LIMIT].remaining", kind: .remaining, unit: "calls", secondary: true, requires: ["limits[name=TIME_LIMIT].currentValue", "limits[name=TIME_LIMIT].usage", "limits[name=TIME_LIMIT].remaining"], presencePaths: ["limits[name=TIME_LIMIT]"], incompleteWhenAnyRequiredPresent: true),
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
        responseFields: ResponseFields(utilization: "totalPercentUsed", resetsAt: "billingCycleEnd", windowSeconds: nil),
        requiredOutputs: RequiredOutputs(minimumWindows: 1, windowIDs: ["plan"]),
        planKey: "membershipType",
        additionalWindows: nil,
        windows: [
            WindowMapping(id: "plan", sourceKey: "individualUsage.plan", resetFormat: .iso8601, windowSeconds: nil, secondary: false, fields: WindowFieldOverride(utilization: "totalPercentUsed", resetsAt: "$.billingCycleEnd"), requiredWhenPresent: false, fallbackGroup: "plan"),
            WindowMapping(id: "plan", sourceKey: "individualUsage.plan", resetFormat: .iso8601, windowSeconds: nil, secondary: false, fields: WindowFieldOverride(resetsAt: "$.billingCycleEnd", used: "used", limit: "limit"), requiredWhenPresent: false, fallbackGroup: "plan"),
            WindowMapping(id: "plan", sourceKey: "individualUsage.overall", resetFormat: .iso8601, windowSeconds: nil, secondary: false, fields: WindowFieldOverride(resetsAt: "$.billingCycleEnd", used: "used", limit: "limit"), requiredWhenPresent: false, fallbackGroup: "plan"),
            WindowMapping(id: "plan", sourceKey: "teamUsage.pooled", resetFormat: .iso8601, windowSeconds: nil, secondary: false, fields: WindowFieldOverride(resetsAt: "$.billingCycleEnd", used: "used", limit: "limit"), requiredWhenPresent: false, fallbackGroup: "plan"),
            WindowMapping(id: "plan_auto", sourceKey: "individualUsage.plan", resetFormat: .iso8601, windowSeconds: nil, secondary: true, label: "Auto-selected models", fields: WindowFieldOverride(utilization: "autoPercentUsed", resetsAt: "$.billingCycleEnd"), requiredWhenPresent: false),
            WindowMapping(id: "plan_api", sourceKey: "individualUsage.plan", resetFormat: .iso8601, windowSeconds: nil, secondary: true, label: "API models", fields: WindowFieldOverride(utilization: "apiPercentUsed", resetsAt: "$.billingCycleEnd"), requiredWhenPresent: false),
        ],
        metricMappings: [
            MetricMapping(id: "spend_ondemand", label: "On-demand spend", sourceKey: "individualUsage.onDemand.used", kind: .spend, unit: "USD", secondary: true, conditions: [FieldCondition(key: "individualUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["individualUsage.onDemand.used", "individualUsage.onDemand.limit"], presencePaths: ["individualUsage.onDemand"], requiresPositive: ["individualUsage.onDemand.limit"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
            MetricMapping(id: "limit_ondemand", label: "On-demand limit", sourceKey: "individualUsage.onDemand.limit", kind: .limit, unit: "USD", secondary: true, conditions: [FieldCondition(key: "individualUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["individualUsage.onDemand.used", "individualUsage.onDemand.limit"], presencePaths: ["individualUsage.onDemand"], requiresPositive: ["individualUsage.onDemand.limit"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
            MetricMapping(id: "spend_ondemand", label: "On-demand spend", sourceKey: "teamUsage.onDemand.used", kind: .spend, unit: "USD", secondary: true, conditions: [FieldCondition(key: "teamUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["teamUsage.onDemand.used", "teamUsage.onDemand.limit"], presencePaths: ["teamUsage.onDemand"], requiresPositive: ["teamUsage.onDemand.limit"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
            MetricMapping(id: "limit_ondemand", label: "On-demand limit", sourceKey: "teamUsage.onDemand.limit", kind: .limit, unit: "USD", secondary: true, conditions: [FieldCondition(key: "teamUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["teamUsage.onDemand.used", "teamUsage.onDemand.limit"], presencePaths: ["teamUsage.onDemand"], requiresPositive: ["teamUsage.onDemand.limit"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
            MetricMapping(id: "spend_ondemand", label: "On-demand spend", sourceKey: "individualUsage.onDemand.used", kind: .spend, unit: "USD", secondary: true, conditions: [FieldCondition(key: "individualUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["individualUsage.onDemand.used", "individualUsage.onDemand.limit"], presencePaths: ["individualUsage.onDemand"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
            MetricMapping(id: "spend_ondemand", label: "On-demand spend", sourceKey: "teamUsage.onDemand.used", kind: .spend, unit: "USD", secondary: true, conditions: [FieldCondition(key: "teamUsage.onDemand.enabled", equals: "true", valueType: "boolean", allowedNonMatches: ["false"])], requires: ["teamUsage.onDemand.used", "teamUsage.onDemand.limit"], presencePaths: ["teamUsage.onDemand"], incompleteWhenAnyRequiredPresent: true, scale: 0.01),
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
            utilization: "used",
            resetsAt: "resetTime",
            windowSeconds: nil,
            utilizationKind: .used,
            allowStringNumbers: true
        ),
        requiredOutputs: RequiredOutputs(minimumWindows: 2, windowIDs: ["session", "weekly"]),
        exhaustiveCollections: [ExhaustiveCollection(
            sourceKeys: ["limits"],
            identityKeys: ["window.timeUnit"],
            allowedIdentities: ["TIME_UNIT_MINUTE"],
            uniqueIdentities: ["TIME_UNIT_MINUTE"],
            durationIdentities: ["TIME_UNIT_MINUTE"],
            duration: WindowDuration(
                unitKey: "window.timeUnit",
                numberKey: "window.duration",
                unitSeconds: ["TIME_UNIT_MINUTE": 60],
                allowedSeconds: [18_000]
            )
        )],
        planKey: "user.membership.level",
        additionalWindows: nil,
        windows: [
            WindowMapping(
                id: "session",
                sourceKey: "limits",
                sourceContainer: .array,
                resetFormat: .iso8601,
                windowSeconds: 18_000,
                secondary: false,
                conditions: [
                    FieldCondition(key: "window.duration", equals: "300"),
                    FieldCondition(key: "window.timeUnit", equals: "TIME_UNIT_MINUTE"),
                ],
                fields: WindowFieldOverride(resetsAt: "detail.resetTime", used: "detail.used", limit: "detail.limit")
            ),
            WindowMapping(
                id: "weekly",
                sourceKey: "usage",
                resetFormat: .iso8601,
                windowSeconds: 604_800,
                secondary: false,
                fields: WindowFieldOverride(resetsAt: "resetTime", used: "used", limit: "limit")
            ),
        ],
        manualEntryHint: "Paste your Kimi Code API key (sk-kimi-...) from kimi.com/code/console. This coding-plan key is separate from a Moonshot open-platform key."
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
