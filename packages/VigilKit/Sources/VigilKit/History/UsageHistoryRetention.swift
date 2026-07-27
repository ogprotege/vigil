import Foundation

enum UsageHistoryRetention {
    /// Removes only duplicate persistence of the same logical fetch or
    /// provider bucket. Distinct successful fetch times are distinct history
    /// observations even when their normalized values are unchanged.
    static func deduplicated(_ samples: [UsageHistorySample]) -> [UsageHistorySample] {
        let grouped = Dictionary(grouping: samples, by: \.accountKey)
        var result: [UsageHistorySample] = []

        for accountSamples in grouped.values {
            let ordered = accountSamples.sorted(by: sampleOrder)
            var exactDeduplicated: [UsageHistorySample] = []
            for sample in ordered {
                var matchingIndex: Int?
                for index in exactDeduplicated.indices.reversed() {
                    let saved = exactDeduplicated[index]
                    guard saved.recordedAt == sample.recordedAt else { break }
                    if saved.hasSamePayload(as: sample) {
                        matchingIndex = index
                        break
                    }
                }
                if let matchingIndex {
                    if sample.retrievedAt >= exactDeduplicated[matchingIndex].retrievedAt {
                        exactDeduplicated[matchingIndex] = sample
                    }
                    continue
                }
                exactDeduplicated.append(sample)
            }

            result.append(contentsOf: exactDeduplicated)
        }
        return result.sorted(by: sampleOrder)
    }

    static func pruned(
        _ samples: [UsageHistorySample],
        now: Date,
        retentionDays: Double,
        maximumObservedEntries: Int,
        maximumProviderBackfillEntries: Int
    ) -> [UsageHistorySample] {
        let cutoff = now.addingTimeInterval(-retentionDays * 86_400)
        let eligible = samples
            .filter { ($0.periodEnd ?? $0.recordedAt) >= cutoff }
            .sorted(by: sampleOrder)

        // Observations made by Vigil and provider-owned imports have separate
        // capacities. A large provider import can prune older imports, but it
        // can never consume the space reserved for on-device observations.
        let observed = prunedWithinSource(
            eligible.filter { $0.source == .observed },
            maximumEntries: maximumObservedEntries
        )
        let providerBackfill = prunedWithinSource(
            eligible.filter { $0.source == .providerBackfill },
            maximumEntries: maximumProviderBackfillEntries
        )
        return (observed + providerBackfill).sorted(by: sampleOrder)
    }

    private static func prunedWithinSource(
        _ eligible: [UsageHistorySample],
        maximumEntries: Int
    ) -> [UsageHistorySample] {
        guard eligible.count > maximumEntries else { return eligible }

        let grouped = Dictionary(grouping: eligible, by: \.accountKey)
        let newest = grouped.values.compactMap { $0.max(by: sampleOrder) }
            .sorted { sampleOrder($1, $0) }
        let oldest = grouped.values.compactMap { $0.min(by: sampleOrder) }
            .sorted(by: sampleOrder)

        var selected = Set<UUID>()
        for sample in newest where selected.count < maximumEntries {
            selected.insert(sample.id)
        }
        for sample in oldest where selected.count < maximumEntries {
            selected.insert(sample.id)
        }
        for sample in eligible.reversed() where selected.count < maximumEntries {
            selected.insert(sample.id)
        }
        return eligible.filter { selected.contains($0.id) }
    }

    private static func sampleOrder(
        _ lhs: UsageHistorySample,
        _ rhs: UsageHistorySample
    ) -> Bool {
        (lhs.recordedAt, lhs.retrievedAt, lhs.id.uuidString)
            < (rhs.recordedAt, rhs.retrievedAt, rhs.id.uuidString)
    }
}
