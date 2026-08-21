import Foundation
import VigilKit

/// Decoder for the money-only history written before Vigil adopted the
/// normalized UsageHistoryStore. This type is migration-only. New provider
/// readings must go directly to UsageHistoryStore.
struct LegacyUsageObservation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let accountKey: String
    let providerId: String
    let spendUSD: Double?
    let remainingUSD: Double?
    let balanceUSD: Double?

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        accountKey: String,
        providerId: String,
        spendUSD: Double? = nil,
        remainingUSD: Double? = nil,
        balanceUSD: Double? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.accountKey = accountKey
        self.providerId = providerId
        self.spendUSD = spendUSD
        self.remainingUSD = remainingUSD
        self.balanceUSD = balanceUSD
    }

    /// The legacy row already represented a reading made by Vigil. Its UUID is
    /// retained so retrying after a crash cannot duplicate the migrated row.
    var historySample: UsageHistorySample? {
        var metrics: [UsageHistoryMetric] = []
        if let spendUSD {
            metrics.append(
                UsageHistoryMetric(
                    id: "legacy_spend_usd",
                    label: "Earlier observed spend",
                    value: spendUSD,
                    unit: "USD",
                    kind: .spend
                )
            )
        }
        if let remainingUSD {
            metrics.append(
                UsageHistoryMetric(
                    id: "legacy_remaining_usd",
                    label: "Earlier observed remaining credit",
                    value: remainingUSD,
                    unit: "USD",
                    kind: .remaining
                )
            )
        }
        if let balanceUSD {
            metrics.append(
                UsageHistoryMetric(
                    id: "legacy_balance_usd",
                    label: "Earlier observed balance",
                    value: balanceUSD,
                    unit: "USD",
                    kind: .balance
                )
            )
        }
        guard !metrics.isEmpty else { return nil }
        return UsageHistorySample(
            id: id,
            source: .observed,
            accountKey: accountKey,
            providerId: providerId,
            recordedAt: recordedAt,
            // The old schema stored one timestamp: when Vigil observed and
            // persisted the value. It is the most truthful retrieval time too.
            retrievedAt: recordedAt,
            metrics: metrics
        )
    }
}

/// Minimal access to `usage-observations.json` during the one-time migration.
/// It intentionally has no append method, so the retired schema cannot receive
/// new data. Account-scoped deletion remains for a failed migration followed by
/// account removal.
struct LegacyUsageObservationStore: Sendable {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("usage-observations.json")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() throws -> [LegacyUsageObservation] {
        guard let data = try TrustedPersistenceFile.readIfPresent(at: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LegacyUsageObservation].self, from: data)
    }

    /// Moves linked accounts' earlier readings into normalized history. Rows
    /// for accounts no longer present in the account index are intentionally
    /// discarded when the legacy file is removed, so deleted private data is
    /// not resurrected as orphan history.
    func migrate(
        to historyStore: UsageHistoryStore,
        activeAccounts: [AccountRef],
        lifecycleStore: AccountLifecycleStore
    ) throws {
        guard exists else { return }
        let activeKeys = Set(activeAccounts.map(\.key))
        let eligible = try load().filter { activeKeys.contains($0.accountKey) }
        let samplesByAccount = Dictionary(
            grouping: eligible.compactMap(\.historySample),
            by: \.accountKey
        )
        for account in activeAccounts.sorted(by: { $0.key < $1.key }) {
            guard let samples = samplesByAccount[account.key], !samples.isEmpty else {
                continue
            }
            guard let generation = try lifecycleStore.captureActiveGeneration(
                accountKey: account.key
            ) else {
                throw AccountLifecycleError.inactiveAccount
            }
            try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try historyStore.importObserved(samples)
            }
        }

        try deleteMigratedFile()
    }

    /// Removes the legacy file only after every eligible row reached the
    /// normalized history store. If removal fails, stable IDs make the next
    /// launch retry safe.
    func deleteMigratedFile() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Removes the retired history file without decoding it. This is used only
    /// after the user explicitly agrees to discard all local history during a
    /// failed account-removal recovery.
    func deleteAll() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func removeAll(accountKey: String) throws {
        let all = try load()
        let remaining = all.filter { $0.accountKey != accountKey }
        guard remaining.count != all.count else { return }
        guard !remaining.isEmpty else {
            try deleteMigratedFile()
            return
        }
        try persist(remaining)
    }

    private func persist(_ observations: [LegacyUsageObservation]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(observations)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
