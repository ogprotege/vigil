import Foundation

/// One rate-limit window of one account, normalized across providers.
/// Mirrors the shape defined in docs/architecture.md and cli/src/providers/types.ts.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let id: String
    /// Percent used, clamped to 0...100.
    public let utilization: Double
    public let resetsAt: Date?
    public let windowSeconds: Int?
    public let secondary: Bool

    public init(id: String, utilization: Double, resetsAt: Date?, windowSeconds: Int?, secondary: Bool) {
        self.id = id
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
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

    public init(
        providerId: String,
        accountKey: String,
        accountLabel: String?,
        planLabel: String?,
        fetchedAt: Date,
        status: SnapshotStatus,
        windows: [UsageWindow]
    ) {
        self.providerId = providerId
        self.accountKey = accountKey
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.fetchedAt = fetchedAt
        self.status = status
        self.windows = windows
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

    public init(
        providerId: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountId: String? = nil,
        label: String? = nil,
        plan: String? = nil
    ) {
        self.providerId = providerId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.label = label
        self.plan = plan
    }
}
