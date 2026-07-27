import Foundation

/// Where a historical sample came from. Provider backfills stay distinct from
/// observations Vigil made while polling the account on this device.
public enum UsageHistorySource: String, Codable, Equatable, Sendable {
    case observed
    case providerBackfill

    public var displayLabel: String {
        switch self {
        case .observed: return "Observed by Vigil"
        case .providerBackfill: return "Imported from provider"
        }
    }
}

/// One normalized provider window at one historical observation.
public struct UsageHistoryWindow: Codable, Equatable, Sendable {
    public let segmentId: String
    public let id: String
    public let label: String?
    public let utilization: Double
    public let used: Double?
    public let limit: Double?
    public let remaining: Double?
    public let resetAt: Date?
    public let windowSeconds: Int?
    public let secondary: Bool

    public init(
        providerId: String,
        id: String,
        label: String? = nil,
        utilization: Double,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        resetAt: Date? = nil,
        windowSeconds: Int? = nil,
        secondary: Bool = false
    ) {
        let normalizedReset = resetAt.map(UsageHistoryDate.normalized)
        self.segmentId = Self.segmentIdentity(
            providerId: providerId,
            windowId: id,
            resetAt: normalizedReset
        )
        self.id = id
        self.label = label
        self.utilization = utilization
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.resetAt = normalizedReset
        self.windowSeconds = windowSeconds
        self.secondary = secondary
    }

    /// Length-prefixed components avoid collisions when provider window IDs
    /// contain punctuation. A changed reset timestamp always starts a segment.
    public static func segmentIdentity(
        providerId: String,
        windowId: String,
        resetAt: Date?
    ) -> String {
        let reset = resetAt.map {
            String(Int64(($0.timeIntervalSince1970 * 1_000).rounded()))
        } ?? "none"
        return "\(providerId.utf8.count):\(providerId)"
            + "|\(windowId.utf8.count):\(windowId)|\(reset)"
    }

    init(providerId: String, window: UsageWindow) {
        self.init(
            providerId: providerId,
            id: window.id,
            label: window.label,
            utilization: window.utilization,
            used: window.used,
            limit: window.limit,
            remaining: window.remaining,
            resetAt: window.resetsAt,
            windowSeconds: window.windowSeconds,
            secondary: window.secondary
        )
    }
}

/// One normalized non-window value at one historical observation.
public struct UsageHistoryMetric: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: Double
    public let unit: String?
    public let kind: UsageMetricKind
    public let secondary: Bool

    public init(
        id: String,
        label: String,
        value: Double,
        unit: String? = nil,
        kind: UsageMetricKind,
        secondary: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.kind = kind
        self.secondary = secondary
    }

    init(metric: UsageMetric) {
        self.init(
            id: metric.id,
            label: metric.label,
            value: metric.value,
            unit: metric.unit,
            kind: metric.kind,
            secondary: metric.secondary
        )
    }
}

/// A complete normalized account reading. `recordedAt` is the live observation
/// or provider bucket time. `retrievedAt` records when Vigil received it.
public struct UsageHistorySample: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let source: UsageHistorySource
    public let accountKey: String
    public let providerId: String
    public let accountLabel: String?
    public let planLabel: String?
    public let recordedAt: Date
    public let periodEnd: Date?
    public let retrievedAt: Date
    public let status: SnapshotStatus
    public let windows: [UsageHistoryWindow]
    public let metrics: [UsageHistoryMetric]
    public let quantities: [UsageHistoryQuantity]

    public init(
        id: UUID = UUID(),
        source: UsageHistorySource,
        accountKey: String,
        providerId: String,
        accountLabel: String? = nil,
        planLabel: String? = nil,
        recordedAt: Date,
        periodEnd: Date? = nil,
        retrievedAt: Date,
        status: SnapshotStatus = .ok,
        windows: [UsageHistoryWindow] = [],
        metrics: [UsageHistoryMetric] = [],
        quantities: [UsageHistoryQuantity] = []
    ) {
        self.id = id
        self.source = source
        self.accountKey = accountKey
        self.providerId = providerId
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.recordedAt = UsageHistoryDate.normalized(recordedAt)
        self.periodEnd = periodEnd.map(UsageHistoryDate.normalized)
        self.retrievedAt = UsageHistoryDate.normalized(retrievedAt)
        self.status = status
        self.windows = windows.sorted(by: Self.windowOrder)
        self.metrics = metrics.sorted(by: Self.metricOrder)
        self.quantities = quantities.sorted(by: Self.quantityOrder)
    }

    /// Converts one accepted live snapshot without changing its timestamp or
    /// claiming provider-supplied historical provenance.
    public init(snapshot: ProviderSnapshot) {
        self.init(
            source: .observed,
            accountKey: snapshot.accountKey,
            providerId: snapshot.providerId,
            accountLabel: snapshot.accountLabel,
            planLabel: snapshot.planLabel,
            recordedAt: snapshot.fetchedAt,
            retrievedAt: snapshot.fetchedAt,
            status: snapshot.status,
            windows: snapshot.windows.map {
                UsageHistoryWindow(providerId: snapshot.providerId, window: $0)
            },
            metrics: snapshot.metrics.map(UsageHistoryMetric.init)
        )
    }

    func hasSamePayload(as other: Self) -> Bool {
        source == other.source
            && accountKey == other.accountKey
            && providerId == other.providerId
            && accountLabel == other.accountLabel
            && planLabel == other.planLabel
            && periodEnd == other.periodEnd
            && status == other.status
            && windows == other.windows
            && metrics == other.metrics
            && quantities == other.quantities
    }

    private static func windowOrder(_ lhs: UsageHistoryWindow, _ rhs: UsageHistoryWindow) -> Bool {
        (lhs.id, lhs.segmentId, lhs.label ?? "") < (rhs.id, rhs.segmentId, rhs.label ?? "")
    }

    private static func metricOrder(_ lhs: UsageHistoryMetric, _ rhs: UsageHistoryMetric) -> Bool {
        (lhs.id, lhs.kind.rawValue, lhs.label) < (rhs.id, rhs.kind.rawValue, rhs.label)
    }

    private static func quantityOrder(
        _ lhs: UsageHistoryQuantity,
        _ rhs: UsageHistoryQuantity
    ) -> Bool {
        (lhs.id, lhs.kind.rawValue, lhs.label) < (rhs.id, rhs.kind.rawValue, rhs.label)
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, accountKey, providerId, accountLabel, planLabel
        case recordedAt, periodEnd, retrievedAt, status, windows, metrics, quantities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            source: try values.decode(UsageHistorySource.self, forKey: .source),
            accountKey: try values.decode(String.self, forKey: .accountKey),
            providerId: try values.decode(String.self, forKey: .providerId),
            accountLabel: try values.decodeIfPresent(String.self, forKey: .accountLabel),
            planLabel: try values.decodeIfPresent(String.self, forKey: .planLabel),
            recordedAt: try values.decode(Date.self, forKey: .recordedAt),
            periodEnd: try values.decodeIfPresent(Date.self, forKey: .periodEnd),
            retrievedAt: try values.decode(Date.self, forKey: .retrievedAt),
            status: try values.decode(SnapshotStatus.self, forKey: .status),
            windows: try values.decode([UsageHistoryWindow].self, forKey: .windows),
            metrics: try values.decode([UsageHistoryMetric].self, forKey: .metrics),
            quantities: try values.decodeIfPresent(
                [UsageHistoryQuantity].self,
                forKey: .quantities
            ) ?? []
        )
    }
}

enum UsageHistoryDate {
    /// Millisecond precision survives Foundation JSON round trips and exceeds
    /// the precision of provider reset contracts without inflating the file.
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
