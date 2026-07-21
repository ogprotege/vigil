import Foundation
import VigilKit

/// One poll observation persisted so Day / Week / Month / Year / Lifetime can
/// show real spend deltas without inventing token counts from thin air.
/// Token-monitor gets absolute tokens from local transcripts; Vigil only sees
/// what provider endpoints return, so this store is the honest phone-side
/// history of those values.
struct UsageObservation: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var recordedAt: Date
    var accountKey: String
    var providerId: String
    var spendUSD: Double?
    var remainingUSD: Double?
    var balanceUSD: Double?

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

    static func from(snapshot: ProviderSnapshot, account: AccountRef, at now: Date = Date()) -> UsageObservation? {
        var spend: Double?
        var remaining: Double?
        var balance: Double?
        for metric in snapshot.metrics {
            let usd = usdValue(metric)
            switch metric.kind {
            case .spend: spend = usd ?? spend
            case .remaining: remaining = usd ?? remaining
            case .balance: balance = usd ?? balance
            case .limit: break
            }
        }
        guard spend != nil || remaining != nil || balance != nil else { return nil }
        return UsageObservation(
            recordedAt: now,
            accountKey: account.key,
            providerId: account.providerId,
            spendUSD: spend,
            remainingUSD: remaining,
            balanceUSD: balance
        )
    }

    private static func usdValue(_ metric: UsageMetric) -> Double? {
        guard let unit = metric.unit?.uppercased(), unit == "USD" || unit == "$" else {
            if metric.unit == nil { return metric.value }
            return nil
        }
        return metric.value
    }
}

struct SpendDeltaSummary: Equatable {
    var amount: Double
    var unitLabel: String
    var hasValue: Bool

    var formatted: String {
        guard hasValue else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }
}

/// Append-only observation log in the shared container. Caps at a rolling year
/// of samples so Lifetime stays meaningful without unbounded growth.
struct UsageObservationStore {
    private let fileURL: URL
    private static let maxAgeDays: Double = 400
    private static let maxEntries = 5_000

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("usage-observations.json")
    }

    func load() throws -> [UsageObservation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UsageObservation].self, from: data)
    }

    func append(_ observation: UsageObservation, now: Date = Date()) throws {
        var all = (try? load()) ?? []
        all.append(observation)
        let cutoff = now.addingTimeInterval(-Self.maxAgeDays * 86_400)
        all = all.filter { $0.recordedAt >= cutoff }
        if all.count > Self.maxEntries {
            all = Array(all.suffix(Self.maxEntries))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(all)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func spendDelta(
        observations: [UsageObservation],
        period: UsagePeriod,
        now: Date = Date()
    ) -> SpendDeltaSummary? {
        let start = periodStart(period, now: now)
        let inPeriod = observations
            .filter { $0.recordedAt >= start && $0.recordedAt <= now }
            .sorted { $0.recordedAt < $1.recordedAt }
        guard !inPeriod.isEmpty else {
            return SpendDeltaSummary(amount: 0, unitLabel: "USD", hasValue: false)
        }

        var total = 0.0
        var saw = false
        let keys = Set(inPeriod.map(\.accountKey))
        for key in keys {
            let series = inPeriod.filter { $0.accountKey == key }
            if let first = series.first?.spendUSD, let last = series.last?.spendUSD {
                total += max(0, last - first)
                saw = true
            } else if let first = series.first?.remainingUSD, let last = series.last?.remainingUSD {
                total += max(0, first - last)
                saw = true
            }
        }
        return SpendDeltaSummary(amount: total, unitLabel: "USD observed", hasValue: saw)
    }

    private static func periodStart(_ period: UsagePeriod, now: Date) -> Date {
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .lifetime:
            return .distantPast
        }
    }
}
