import Foundation

/// Counted historical usage that is neither money nor a reset percentage.
/// `other` remains available for a provider-defined quantity whose stable ID
/// and label are retained without pretending it is a known token family.
public enum UsageHistoryQuantityKind: String, Codable, Equatable, Sendable {
    case inputTokens
    case outputTokens
    case cachedInputTokens
    case cacheReadTokens
    case cacheWriteTokens
    case requests
    case other
}

public struct UsageHistoryQuantity: Codable, Equatable, Sendable {
    /// Stable provider-independent identifier within one historical sample.
    public let id: String
    public let kind: UsageHistoryQuantityKind
    public let label: String
    public let value: Double
    public let unit: String

    public init(
        id: String,
        kind: UsageHistoryQuantityKind,
        label: String,
        value: Double,
        unit: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.unit = unit
    }
}
