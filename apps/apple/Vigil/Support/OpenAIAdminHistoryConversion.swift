import Foundation
import VigilKit

extension OpenAIAdminHistoryResult {
    /// Converts official organization rows without joining cost onto token
    /// groups. OpenAI exposes different grouping dimensions for the two
    /// reports, so a join would duplicate or falsely attribute spend.
    func historySamples(
        accountKey: String,
        accountLabel: String? = nil,
        planLabel: String? = nil
    ) -> [UsageHistorySample] {
        let tokenSamples = Dictionary(grouping: tokenPoints, by: BucketKey.init)
            .map { key, points in
                UsageHistorySample(
                    source: .providerBackfill,
                    accountKey: accountKey,
                    providerId: "openai",
                    accountLabel: accountLabel,
                    planLabel: planLabel,
                    recordedAt: key.start,
                    periodEnd: key.end,
                    retrievedAt: key.retrievedAt,
                    quantities: points.flatMap(\.quantities)
                )
            }
        let costSamples = Dictionary(grouping: costPoints, by: BucketKey.init)
            .map { key, points in
                UsageHistorySample(
                    source: .providerBackfill,
                    accountKey: accountKey,
                    providerId: "openai",
                    accountLabel: accountLabel,
                    planLabel: planLabel,
                    recordedAt: key.start,
                    periodEnd: key.end,
                    retrievedAt: key.retrievedAt,
                    metrics: points.map { point in
                        UsageHistoryMetric(
                            id: "openai.cost|\(point.groupIdentity)",
                            label: point.costLabel,
                            value: point.amount,
                            unit: point.currency,
                            kind: .spend
                        )
                    }
                )
            }
        return (tokenSamples + costSamples).sorted {
            ($0.recordedAt, $0.metrics.isEmpty ? 0 : 1)
                < ($1.recordedAt, $1.metrics.isEmpty ? 0 : 1)
        }
    }
}

private struct BucketKey: Hashable {
    let start: Date
    let end: Date
    let retrievedAt: Date

    init(_ point: OpenAIAdminTokenPoint) {
        start = point.bucketStart
        end = point.bucketEnd
        retrievedAt = point.retrievedAt
    }

    init(_ point: OpenAIAdminCostPoint) {
        start = point.bucketStart
        end = point.bucketEnd
        retrievedAt = point.retrievedAt
    }
}

private extension OpenAIAdminTokenPoint {
    var quantities: [UsageHistoryQuantity] {
        let group = groupIdentity
        let suffix = groupLabel
        return [
            quantity("input", .inputTokens, "Input tokens", inputTokens, group, suffix),
            quantity("output", .outputTokens, "Output tokens", outputTokens, group, suffix),
            quantity("cached-input", .cachedInputTokens, "Cached input tokens", cachedInputTokens, group, suffix),
            quantity("input-audio", .other, "Input audio tokens", inputAudioTokens, group, suffix),
            quantity("output-audio", .other, "Output audio tokens", outputAudioTokens, group, suffix),
            quantity("requests", .requests, "Model requests", requestCount, group, suffix),
        ]
    }

    var groupIdentity: String {
        dimensions.map { "\($0.0)=\($0.1 ?? "all")" }.joined(separator: "|")
    }

    var groupLabel: String {
        let values = dimensions.compactMap { key, value in value.map { "\(key) \($0)" } }
        return values.isEmpty ? "all organization activity" : values.joined(separator: ", ")
    }

    var dimensions: [(String, String?)] {
        [("model", model)]
    }

    func quantity(
        _ id: String,
        _ kind: UsageHistoryQuantityKind,
        _ label: String,
        _ value: Int64,
        _ group: String,
        _ suffix: String
    ) -> UsageHistoryQuantity {
        UsageHistoryQuantity(
            id: "openai.\(id)|\(group)",
            kind: kind,
            label: "\(label) · \(suffix)",
            value: Double(value),
            unit: id == "requests" ? "requests" : "tokens"
        )
    }
}

private extension OpenAIAdminCostPoint {
    var groupIdentity: String {
        "line-item=\(lineItem ?? "all")"
    }

    var costLabel: String {
        lineItem ?? "API organization cost"
    }
}
