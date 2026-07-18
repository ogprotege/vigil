import Foundation

public struct LedgerEntry: Codable, Equatable, Sendable {
    public var nextAllowedAt: Date
    public var consecutive429: Int

    public init(nextAllowedAt: Date, consecutive429: Int) {
        self.nextAllowedAt = nextAllowedAt
        self.consecutive429 = consecutive429
    }
}

public protocol LedgerStore: Sendable {
    func load() -> [String: LedgerEntry]
    func save(_ ledger: [String: LedgerEntry])
}

/// Persists the ledger as JSON in a directory shared between the app and the
/// widget extension (the App Group container) so every process draws from ONE
/// polling budget. This is the mechanism that keeps Vigil out of the 429 jail.
public struct FileLedgerStore: LedgerStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("fetch-ledger.json")
    }

    public func load() -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: LedgerEntry].self, from: data)) ?? [:]
    }

    public func save(_ ledger: [String: LedgerEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Single-flight, min-interval, jittered, 429-backoff fetch gatekeeper.
/// Every fetch in every process MUST pass through acquire/recordResult.
public actor FetchScheduler {
    private let store: LedgerStore
    private let now: @Sendable () -> Date
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private var inFlight: Set<String> = []

    public init(
        store: LedgerStore,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { max in
            max <= 0 ? 0 : TimeInterval.random(in: 0...max)
        }
    ) {
        self.store = store
        self.now = now
        self.jitter = jitter
    }

    public func nextAllowedFetch(accountKey: String) -> Date? {
        store.load()[accountKey]?.nextAllowedAt
    }

    /// True if a fetch may start now: not already in flight anywhere in this
    /// process, and the shared ledger's clock has passed. Callers MUST follow
    /// with recordResult (or release on abandonment).
    public func acquire(accountKey: String, policy: PollPolicy) -> Bool {
        guard !inFlight.contains(accountKey) else { return false }
        if let entry = store.load()[accountKey], now() < entry.nextAllowedAt {
            return false
        }
        inFlight.insert(accountKey)
        return true
    }

    public func release(accountKey: String) {
        inFlight.remove(accountKey)
    }

    public func recordResult(accountKey: String, policy: PollPolicy, status: SnapshotStatus) {
        var ledger = store.load()
        var entry = ledger[accountKey] ?? LedgerEntry(nextAllowedAt: .distantPast, consecutive429: 0)

        if status == .rateLimited {
            entry.consecutive429 += 1
            let exponent = Double(entry.consecutive429 - 1)
            let backoff = min(policy.backoff429BaseSeconds * pow(2, exponent), policy.backoffMaxSeconds)
            entry.nextAllowedAt = now().addingTimeInterval(backoff + jitter(policy.jitterSeconds))
        } else {
            entry.consecutive429 = 0
            entry.nextAllowedAt = now().addingTimeInterval(policy.minSeconds + jitter(policy.jitterSeconds))
        }

        ledger[accountKey] = entry
        store.save(ledger)
        inFlight.remove(accountKey)
    }
}
