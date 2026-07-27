import Foundation

/// One rate-limit window of one account, normalized across providers.
/// The shared provider fixtures pin this normalized shape.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let id: String
    /// Human display name for a provider-scoped window (e.g. a model name),
    /// present only when the response carries one; nil for static windows whose
    /// name is derived from the id at the UI layer.
    public let label: String?
    /// Percent used, clamped to 0...100.
    public let utilization: Double
    /// Provider-supplied absolute usage, when the response exposes both sides
    /// of the quota. Nil for percentage-only provider contracts.
    public let used: Double?
    /// Provider-supplied absolute quota, when available. Vigil never invents
    /// a denominator from a utilization percentage.
    public let limit: Double?
    /// Exact allowance left when the provider supplies it, or when it can be
    /// derived without estimation from exact `used` and `limit` values.
    public let remaining: Double?
    public let resetsAt: Date?
    public let windowSeconds: Int?
    public let secondary: Bool

    public init(
        id: String,
        utilization: Double,
        resetsAt: Date?,
        windowSeconds: Int?,
        secondary: Bool,
        label: String? = nil,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.secondary = secondary
    }
}

/// A provider value that is not a reset-based rate window. API gateways often
/// expose account spend, credit limits, or remaining balances instead of a
/// session percentage. Keeping these as first-class metrics avoids inventing a
/// misleading percentage when the provider has not supplied a denominator.
public enum UsageMetricKind: String, Codable, Sendable {
    case balance
    case spend
    case limit
    case remaining
}

public struct UsageMetric: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: UsageMetricKind
    public let value: Double
    /// ISO-4217 currency code or another short provider-defined unit.
    public let unit: String?
    public let secondary: Bool

    public init(
        id: String,
        label: String,
        kind: UsageMetricKind,
        value: Double,
        unit: String?,
        secondary: Bool
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.unit = unit
        self.secondary = secondary
    }
}

public enum SnapshotStatus: String, Codable, Sendable {
    case ok
    case authExpired
    case rateLimited
    case schemaChanged
    case network
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let providerId: String
    public let accountKey: String
    public let accountLabel: String?
    public let planLabel: String?
    public let fetchedAt: Date
    public let status: SnapshotStatus
    public let windows: [UsageWindow]
    public let metrics: [UsageMetric]

    public init(
        providerId: String,
        accountKey: String,
        accountLabel: String?,
        planLabel: String?,
        fetchedAt: Date,
        status: SnapshotStatus,
        windows: [UsageWindow],
        metrics: [UsageMetric] = []
    ) {
        self.providerId = providerId
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.fetchedAt = fetchedAt
        self.status = status
        self.windows = windows
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case providerId
        case accountKey
        case accountLabel
        case planLabel
        case fetchedAt
        case status
        case windows
        case metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        accountKey = try container.decode(String.self, forKey: .accountKey)
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        planLabel = try container.decodeIfPresent(String.self, forKey: .planLabel)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        status = try container.decode(SnapshotStatus.self, forKey: .status)
        windows = try container.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        // Backward compatible with snapshots written before scalar gateway
        // metrics were introduced.
        metrics = try container.decodeIfPresent([UsageMetric].self, forKey: .metrics) ?? []
    }
}

public struct Credentials: Codable, Equatable, Sendable {
    public let providerId: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountId: String?
    public var label: String?
    public var plan: String?
    /// "mint" when Vigil owns this token pair and may refresh it. Copied
    /// credentials are never refreshed — rotation would race the owning CLI
    /// (ADR-0005).
    public var source: String?

    public init(
        providerId: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountId: String? = nil,
        label: String? = nil,
        plan: String? = nil,
        source: String? = nil
    ) {
        self.providerId = providerId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.label = label
        self.plan = plan
        self.source = source
    }
}
