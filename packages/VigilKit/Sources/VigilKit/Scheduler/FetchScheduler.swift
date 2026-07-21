import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LedgerEntry: Codable, Equatable, Sendable {
    public var nextAllowedAt: Date
    public var consecutive429: Int
    /// Identifies the process-local acquisition that currently owns this
    /// account's shared fetch slot. Optional for backward-compatible decoding
    /// of ledgers written before cross-process leases were introduced.
    public var leaseOwner: String?
    /// A crashed process cannot hold the shared fetch slot forever. A new
    /// caller may replace the lease after this instant.
    public var leaseExpiresAt: Date?

    public init(
        nextAllowedAt: Date,
        consecutive429: Int,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil
    ) {
        self.nextAllowedAt = nextAllowedAt
        self.consecutive429 = consecutive429
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
    }
}

public enum LedgerStoreError: Error, LocalizedError, Sendable {
    case prepareDirectory(String)
    case openLock(path: String, code: Int32)
    case lock(path: String, code: Int32)
    case read(path: String, message: String)
    case decode(path: String, message: String)
    case encode(String)
    case write(path: String, message: String)
    case permissions(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .prepareDirectory(let message):
            return "Could not prepare the fetch-ledger directory: \(message)"
        case .openLock(let path, let code):
            return "Could not open ledger lock \(path) (errno \(code))."
        case .lock(let path, let code):
            return "Could not lock ledger \(path) (errno \(code))."
        case .read(let path, let message):
            return "Could not read ledger \(path): \(message)"
        case .decode(let path, let message):
            return "Could not decode ledger \(path): \(message)"
        case .encode(let message):
            return "Could not encode the fetch ledger: \(message)"
        case .write(let path, let message):
            return "Could not write ledger \(path): \(message)"
        case .permissions(let path, let code):
            return "Could not secure ledger permissions for \(path) (errno \(code))."
        }
    }
}

public protocol LedgerStore: Sendable {
    func load() throws -> [String: LedgerEntry]

    /// Runs one read-modify-write transaction under a lock shared by every
    /// app process using this store. Implementations must not return until the
    /// mutation is saved or an error is thrown.
    func update(_ mutation: (inout [String: LedgerEntry]) -> Void) throws
}

/// Persists the ledger as JSON in a directory shared between the app and the
/// widget extension (the App Group container) so every process draws from ONE
/// polling budget. This is the mechanism that keeps Vigil out of the 429 jail.
public struct FileLedgerStore: LedgerStore {
    private static let maximumConsecutive429 = 63
    private let directoryURL: URL
    private let fileURL: URL
    private let lockURL: URL

    public init(directory: URL) {
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent("fetch-ledger.json")
        self.lockURL = directory.appendingPathComponent("fetch-ledger.lock")
    }

    public func load() throws -> [String: LedgerEntry] {
        try prepareDirectory()
        return try withFileLock(LOCK_SH) {
            try loadUnlocked()
        }
    }

    public func update(_ mutation: (inout [String: LedgerEntry]) -> Void) throws {
        try prepareDirectory()
        try withFileLock(LOCK_EX) {
            var ledger = try loadUnlocked()
            let original = ledger
            mutation(&ledger)
            guard ledger != original else { return }
            try saveUnlocked(ledger)
        }
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw LedgerStoreError.prepareDirectory(error.localizedDescription)
        }
    }

    private func loadUnlocked() throws -> [String: LedgerEntry] {
        let data: Data
        do {
            guard let existing = try PersistenceFileIO.readIfPresent(at: fileURL) else {
                return [:]
            }
            data = existing
        } catch {
            throw LedgerStoreError.read(path: fileURL.path, message: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let ledger = try decoder.decode([String: LedgerEntry].self, from: data)
            for (accountKey, entry) in ledger {
                guard !accountKey.isEmpty else {
                    throw LedgerStoreError.decode(
                        path: fileURL.path,
                        message: "An account key is empty."
                    )
                }
                guard (0...Self.maximumConsecutive429).contains(entry.consecutive429) else {
                    throw LedgerStoreError.decode(
                        path: fileURL.path,
                        message: "A consecutive-429 counter is outside its safe range."
                    )
                }
                let hasOwner = entry.leaseOwner?.isEmpty == false
                let hasExpiry = entry.leaseExpiresAt != nil
                guard hasOwner == hasExpiry else {
                    throw LedgerStoreError.decode(
                        path: fileURL.path,
                        message: "A lease owner and expiry must appear together."
                    )
                }
            }
            return ledger
        } catch {
            // A corrupt ledger must fail closed. Treating it as empty would
            // silently discard the shared rate-limit and lease state.
            throw LedgerStoreError.decode(path: fileURL.path, message: error.localizedDescription)
        }
    }

    private func saveUnlocked(_ ledger: [String: LedgerEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ledger)
        } catch {
            throw LedgerStoreError.encode(error.localizedDescription)
        }
        do {
            try PersistenceFileIO.writeAtomically(data, to: fileURL)
        } catch {
            throw LedgerStoreError.write(path: fileURL.path, message: error.localizedDescription)
        }
    }

    private func withFileLock<T>(_ operation: Int32, body: () throws -> T) throws -> T {
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw LedgerStoreError.openLock(path: lockURL.path, code: errno)
        }
        defer { close(descriptor) }

        // Tighten permissions even if this file predates the current code.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw LedgerStoreError.permissions(path: lockURL.path, code: errno)
        }
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: lockURL.path
            )
        } catch {
            throw LedgerStoreError.write(path: lockURL.path, message: error.localizedDescription)
        }
        #endif
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else {
                throw LedgerStoreError.lock(path: lockURL.path, code: errno)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// Single-flight, min-interval, jittered, 429-backoff fetch gatekeeper.
/// Every fetch in every process MUST pass through acquire/recordResult.
public actor FetchScheduler {
    private let store: LedgerStore
    private let now: @Sendable () -> Date
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private let leaseDuration: TimeInterval
    private static let maximumConsecutive429 = 63
    /// The value is also persisted in the shared ledger. Keeping it here lets
    /// this actor prove ownership before release or result recording.
    private var inFlight: [String: String] = [:]
    /// Keyed by account. A single shared slot was overwritten and cleared by
    /// whichever account happened to run next on this reentrant actor —
    /// `refreshAll` fans every account out concurrently — so a ledger write
    /// failure could be attributed to the wrong account, or cleared before its
    /// owner read it and reported as an ordinary poll-floor deferral. That
    /// silently broke the fail-closed-and-surface rule for storage errors.
    private var lastStoreError: [String: String] = [:]

    public init(
        store: LedgerStore,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { max in
            max <= 0 ? 0 : TimeInterval.random(in: 0...max)
        },
        leaseDuration: TimeInterval = 5 * 60
    ) {
        self.store = store
        self.now = now
        self.jitter = jitter
        self.leaseDuration = leaseDuration.isFinite ? max(1, leaseDuration) : 5 * 60
    }

    public func nextAllowedFetch(accountKey: String) -> Date? {
        do {
            let entry = try store.load()[accountKey]
            lastStoreError[accountKey] = nil
            guard let entry else { return nil }
            // When a process currently owns the slot, the lease expiry is the
            // earliest safe retry even if the ordinary poll clock has passed.
            return max(entry.nextAllowedAt, entry.leaseExpiresAt ?? .distantPast)
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return nil
        }
    }

    /// A caller can distinguish an ordinary ledger refusal from a storage
    /// failure without changing the established non-throwing fetch API.
    public func persistenceErrorDescription(accountKey: String) -> String? {
        lastStoreError[accountKey]
    }

    /// True if a fetch may start now. The check and lease write happen in one
    /// locked transaction shared by the app and widget processes. Callers MUST
    /// follow with recordResult (or release on abandonment).
    public func acquire(accountKey: String, policy: PollPolicy) -> Bool {
        guard inFlight[accountKey] == nil else {
            lastStoreError[accountKey] = nil
            return false
        }

        let owner = UUID().uuidString
        let acquiredAt = now()
        var acquired = false
        do {
            try store.update { ledger in
                var entry = ledger[accountKey]
                    ?? LedgerEntry(nextAllowedAt: .distantPast, consecutive429: 0)
                guard acquiredAt >= entry.nextAllowedAt else { return }
                if let leaseExpiresAt = entry.leaseExpiresAt,
                   leaseExpiresAt > acquiredAt {
                    return
                }

                entry.leaseOwner = owner
                // The lease is the crash-recovery floor: after a hard crash the
                // account stays blocked until it expires, so it must never be
                // shorter than the provider's poll floor — otherwise a
                // crash-looping process could poll faster than minSeconds.
                let crashRecoveryFloor = max(leaseDuration, policy.minSeconds)
                entry.leaseExpiresAt = acquiredAt.addingTimeInterval(crashRecoveryFloor)
                ledger[accountKey] = entry
                acquired = true
            }
            lastStoreError[accountKey] = nil
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return false
        }

        if acquired {
            inFlight[accountKey] = owner
        }
        return acquired
    }

    /// Releases only the lease created by this scheduler. A late cancellation
    /// from an expired owner cannot clear a replacement process's lease.
    @discardableResult
    public func release(accountKey: String) -> Bool {
        guard let owner = inFlight.removeValue(forKey: accountKey) else {
            return false
        }
        var released = false
        do {
            try store.update { ledger in
                guard var entry = ledger[accountKey],
                      entry.leaseOwner == owner
                else { return }
                entry.leaseOwner = nil
                entry.leaseExpiresAt = nil
                ledger[accountKey] = entry
                released = true
            }
            lastStoreError[accountKey] = nil
            return released
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return false
        }
    }

    /// Forgets an account's ledger state entirely. Call when the account is
    /// removed so a later re-link performs a genuine live verify instead of
    /// being refused by the departed account's poll clock.
    @discardableResult
    public func clear(accountKey: String) -> Bool {
        inFlight[accountKey] = nil
        do {
            try store.update { ledger in
                ledger[accountKey] = nil
            }
            lastStoreError[accountKey] = nil
            return true
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return false
        }
    }

    /// Releases the lease **and** advances the poll floor, for an attempt whose
    /// request was already dispatched but whose outcome is unknown — a
    /// cancelled in-flight fetch.
    ///
    /// A bare `release` is wrong there: it clears the lease without touching
    /// `nextAllowedAt`, which is `.distantPast` on a never-fetched account, so
    /// the next `acquire` succeeds immediately. Since cancellation is trivially
    /// user-driven (backgrounding the app cancels the refresh task group), that
    /// let a foreground/background cycle send one provider request per cycle
    /// with no floor at all. The bytes were already on the wire and counted
    /// against the provider's rate limit, so the clock must be charged.
    ///
    /// Unlike `recordResult` this never touches `consecutive429`: an unknown
    /// outcome is not evidence of rate limiting in either direction.
    @discardableResult
    public func chargeFloor(accountKey: String, policy: PollPolicy) -> Bool {
        let owner = inFlight.removeValue(forKey: accountKey)
        let recordedAt = now()
        var charged = false
        do {
            try store.update { ledger in
                var entry = ledger[accountKey]
                    ?? LedgerEntry(nextAllowedAt: .distantPast, consecutive429: 0)
                if let owner {
                    guard entry.leaseOwner == owner else { return }
                } else if entry.leaseOwner != nil,
                          (entry.leaseExpiresAt ?? .distantFuture) > recordedAt {
                    return
                }
                let minimum = policy.minSeconds.isFinite ? max(0, policy.minSeconds) : 0
                let floor = recordedAt.addingTimeInterval(minimum + boundedJitter(policy.jitterSeconds))
                // Never pull an existing floor earlier.
                entry.nextAllowedAt = max(entry.nextAllowedAt, floor)
                entry.leaseOwner = nil
                entry.leaseExpiresAt = nil
                ledger[accountKey] = entry
                charged = true
            }
            lastStoreError[accountKey] = nil
            return charged
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return false
        }
    }

    /// Records only the result belonging to this scheduler's current lease.
    /// Calls without a preceding acquire remain supported for administrative
    /// and test use, but never overwrite another process's active lease.
    @discardableResult
    public func recordResult(accountKey: String, policy: PollPolicy, status: SnapshotStatus) -> Bool {
        let owner = inFlight.removeValue(forKey: accountKey)
        let recordedAt = now()
        var recorded = false
        do {
            try store.update { ledger in
                var entry = ledger[accountKey]
                    ?? LedgerEntry(nextAllowedAt: .distantPast, consecutive429: 0)

                if let owner {
                    // The lease may have expired, but the result is still ours
                    // if no newer process replaced its owner token.
                    guard entry.leaseOwner == owner else { return }
                } else if entry.leaseOwner != nil,
                          (entry.leaseExpiresAt ?? .distantFuture) > recordedAt {
                    return
                }

                if status == .rateLimited {
                    entry.consecutive429 = min(
                        max(0, entry.consecutive429),
                        Self.maximumConsecutive429
                    )
                    if entry.consecutive429 < Self.maximumConsecutive429 {
                        entry.consecutive429 += 1
                    }
                    let exponent = Double(entry.consecutive429 - 1)
                    let base = policy.backoff429BaseSeconds.isFinite
                        ? max(0, policy.backoff429BaseSeconds)
                        : 0
                    let cap = policy.backoffMaxSeconds.isFinite
                        ? max(0, policy.backoffMaxSeconds)
                        : base
                    let calculated = base * pow(2, exponent)
                    let backoff = calculated.isFinite ? min(calculated, cap) : cap
                    entry.nextAllowedAt = recordedAt.addingTimeInterval(
                        backoff + boundedJitter(policy.jitterSeconds)
                    )
                } else {
                    entry.consecutive429 = 0
                    let minimum = policy.minSeconds.isFinite
                        ? max(0, policy.minSeconds)
                        : 0
                    entry.nextAllowedAt = recordedAt.addingTimeInterval(
                        minimum + boundedJitter(policy.jitterSeconds)
                    )
                }

                entry.leaseOwner = nil
                entry.leaseExpiresAt = nil
                ledger[accountKey] = entry
                recorded = true
            }
            lastStoreError[accountKey] = nil
            return recorded
        } catch {
            lastStoreError[accountKey] = error.localizedDescription
            return false
        }
    }

    private func boundedJitter(_ upperBound: TimeInterval) -> TimeInterval {
        guard upperBound.isFinite, upperBound > 0 else { return 0 }
        let value = jitter(upperBound)
        guard value.isFinite else { return 0 }
        return min(max(0, value), upperBound)
    }
}
