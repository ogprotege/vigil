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
        // Providers can report several metrics of one kind — Moonshot maps
        // `balance` (primary) plus `balance_cash` and `balance_voucher`
        // (both secondary). Prefer the primary metric and, among equals, the
        // first; taking the last would record the voucher sub-balance as the
        // account balance.
        var spend: Candidate?
        var remaining: Candidate?
        var balance: Candidate?
        for metric in snapshot.metrics {
            guard let usd = usdValue(metric) else { continue }
            let candidate = Candidate(value: usd, secondary: metric.secondary)
            switch metric.kind {
            case .spend: spend = preferred(spend, candidate)
            case .remaining: remaining = preferred(remaining, candidate)
            case .balance: balance = preferred(balance, candidate)
            case .limit: break
            }
        }
        guard spend != nil || remaining != nil || balance != nil else { return nil }
        return UsageObservation(
            recordedAt: now,
            accountKey: account.key,
            providerId: account.providerId,
            spendUSD: spend?.value,
            remainingUSD: remaining?.value,
            balanceUSD: balance?.value
        )
    }

    private struct Candidate {
        var value: Double
        var secondary: Bool
    }

    /// Keeps the incumbent unless it is secondary and the challenger is primary.
    private static func preferred(_ current: Candidate?, _ next: Candidate) -> Candidate {
        guard let current else { return next }
        if current.secondary && !next.secondary { return next }
        return current
    }

    /// True when the two observations carry the same money values, so appending
    /// the newer one would add a row that contributes nothing to any delta.
    func hasSameValues(as other: UsageObservation) -> Bool {
        func same(_ lhs: Double?, _ rhs: Double?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (l?, r?): return abs(l - r) < 0.000_001
            default: return false
            }
        }
        return same(spendUSD, other.spendUSD)
            && same(remainingUSD, other.remainingUSD)
            && same(balanceUSD, other.balanceUSD)
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

    /// Appends an observation and returns the pruned array that was persisted,
    /// so callers do not have to decode the file a second time just to refresh
    /// their in-memory copy.
    @discardableResult
    func append(_ observation: UsageObservation, now: Date = Date()) throws -> [UsageObservation] {
        // Fail closed on an unreadable file, like SnapshotStore and
        // PendingEventStore do. Swallowing the error degraded the history to
        // `[]` and then overwrote the file with a single row, permanently
        // destroying up to 400 days of spend history — and inverting the
        // alert's promise that totals recover "until the next successful
        // refresh", since the next refresh was what deleted them.
        var all = try load()
        // Polling runs on a timer, so an idle account would otherwise append an
        // identical row every poll interval and evict its own baseline. A row
        // that repeats the previous values contributes 0 to every delta, so
        // only the timestamp would change — drop it and keep the history long.
        if let last = all.last(where: { $0.accountKey == observation.accountKey }),
           last.hasSameValues(as: observation) {
            return all
        }
        all.append(observation)
        all = Self.pruned(all, now: now)
        try persist(all)
        return all
    }

    /// Drops every observation for one account — used when the account is
    /// removed, so its spend stops feeding the Home hero and its dollar amounts
    /// leave the shared container.
    @discardableResult
    func removeAll(accountKey: String, now: Date = Date()) throws -> [UsageObservation] {
        // Also fail closed: swallowing the read error made the guard below see
        // "nothing changed" and report success, leaving the removed account's
        // dated dollar amounts on disk while the UI — and PrivacyView's
        // "Vigil reports any failed deletion" — said they were gone.
        let all = try load()
        let remaining = all.filter { $0.accountKey != accountKey }
        guard remaining.count != all.count else { return all }
        try persist(remaining)
        return remaining
    }

    private func persist(_ observations: [UsageObservation]) throws {
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

    /// Age-prunes, then caps — but never evicts an account's oldest surviving
    /// sample. That row is the baseline every period delta measures from;
    /// dropping it silently shortens "Lifetime" to whatever the cap happens to
    /// hold and makes the number shrink over time.
    static func pruned(_ observations: [UsageObservation], now: Date) -> [UsageObservation] {
        let cutoff = now.addingTimeInterval(-maxAgeDays * 86_400)
        var all = observations
            .filter { $0.recordedAt >= cutoff }
            .sorted { $0.recordedAt < $1.recordedAt }
        guard all.count > maxEntries else { return all }

        var baselineIDs = Set<UUID>()
        for key in Set(all.map(\.accountKey)) {
            if let oldest = all.first(where: { $0.accountKey == key }) {
                baselineIDs.insert(oldest.id)
            }
        }
        var keep = Array(all.suffix(maxEntries))
        let kept = Set(keep.map(\.id))
        let baselines = all.filter { baselineIDs.contains($0.id) && !kept.contains($0.id) }
        if !baselines.isEmpty {
            keep = (baselines + keep).sorted { $0.recordedAt < $1.recordedAt }
        }
        all = keep
        return all
    }

    static func spendDelta(
        observations: [UsageObservation],
        period: UsagePeriod,
        now: Date = Date()
    ) -> SpendDeltaSummary? {
        let start = periodStart(period, now: now)
        let upToNow = observations
            .filter { $0.recordedAt <= now }
            .sorted { $0.recordedAt < $1.recordedAt }
        let inPeriod = upToNow.filter { $0.recordedAt >= start }
        guard !inPeriod.isEmpty else {
            return SpendDeltaSummary(amount: 0, unitLabel: "USD", hasValue: false)
        }

        var total = 0.0
        var saw = false
        let keys = Set(inPeriod.map(\.accountKey))
        for key in keys {
            // Seed with the account's last reading *before* the window. Spend
            // for a range is (value at the end) − (value at the start), and the
            // best estimate of the value at the start is the last reading taken
            // before it. Without the seed a range that opens with a single
            // reading has nothing to measure against and reports no value at
            // all — which is most days, since an idle counter's repeated
            // readings are deduplicated on write.
            let history = upToNow.filter { $0.accountKey == key }
            let seed = history.last { $0.recordedAt < start }
            let series = (seed.map { [$0] } ?? []) + history.filter { $0.recordedAt >= start }
            // A cumulative spend counter is not monotonic across the window:
            // openai/spend_month, github/spend_month and claude/extra_used all
            // reset monthly, and .week/.month/.year are rolling ranges that
            // always straddle a reset. Summing consecutive rises — and treating
            // a drop as "the counter reset, so the new reading is the spend
            // since it did" — stays correct across resets, where last-minus-
            // first silently reports 0 or a meaningless difference.
            let spends = series.compactMap(\.spendUSD)
            if spends.count >= 2 {
                total += risingTotal(spends)
                saw = true
                continue
            }
            // Remaining/balance run the other way: consumption is a fall, and a
            // rise is a top-up that tells us nothing about spend, so it adds 0.
            let falling = series.compactMap(\.remainingUSD)
            if falling.count >= 2 {
                total += fallingTotal(falling)
                saw = true
                continue
            }
            let balances = series.compactMap(\.balanceUSD)
            if balances.count >= 2 {
                total += fallingTotal(balances)
                saw = true
            }
        }
        // One sample is a reading, not a delta: `last - first` over a
        // single-element series is identically 0, which rendered a confident
        // "$0.00" hero. Report no value so the caller can say so honestly.
        return SpendDeltaSummary(amount: total, unitLabel: "USD observed", hasValue: saw)
    }

    /// Fraction of the previous reading below which a drop is read as a counter
    /// reset rather than a downward correction. A real reset restarts near zero
    /// and polls run every few minutes, so the reading right after one is a
    /// small fraction of the reading before it.
    private static let resetRatio = 0.5

    /// Sum of increases in a cumulative counter.
    ///
    /// A decrease is ambiguous: the provider's counter may have reset (spend
    /// since the reset is the new reading), or the same counter may have been
    /// corrected downward — a refund for a failed generation, a restated usage
    /// item, a rounding change. Booking the full new reading for *any* decrease
    /// makes the penalty for guessing wrong the entire counter magnitude, so a
    /// two-cent refund on a $12.50 counter would report $12.48 of spend, and an
    /// oscillating value would re-add it on every downward tick.
    ///
    /// So only a drop far enough below the previous reading counts as a reset.
    /// A shallow drop is treated as a correction and contributes nothing —
    /// under-reporting slightly rather than inventing a large number, which is
    /// the honest direction for a monitor to err in.
    private static func risingTotal(_ values: [Double]) -> Double {
        var total = 0.0
        for (previous, current) in zip(values, values.dropFirst()) {
            if current >= previous {
                total += current - previous
            } else if current < previous * resetRatio {
                total += max(0, current)
            }
        }
        return total
    }

    /// Sum of decreases in a draining balance. A rise is a top-up and adds 0.
    private static func fallingTotal(_ values: [Double]) -> Double {
        var total = 0.0
        for (previous, current) in zip(values, values.dropFirst()) where previous > current {
            total += previous - current
        }
        return total
    }

    static func periodStart(_ period: UsagePeriod, now: Date) -> Date {
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
