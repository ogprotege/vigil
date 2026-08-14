import Foundation

/// Threshold crossings detected by a process that must not deliver
/// notifications itself (the widget extension) are parked here, in the shared
/// App Group container, until the app process drains and delivers them.
/// Events merge only within the same window, threshold, and provider reset
/// segment. A crossing from a new quota cycle must never be acknowledged as if
/// it were the older cycle's event.
public struct PendingEventStore: Sendable {
    public static let maximumEventsPerAccount = 64
    public static let maximumEventAge: TimeInterval = 7 * 24 * 3_600
    public static let maximumEncodedBytes = 65_536

    private struct EventIdentity: Hashable {
        let windowId: String
        let threshold: Int
        let resetSegment: Int64?
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ accountKey: String) -> URL {
        // Preserve the v1 filename mapping for backward compatibility.
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("pending-events-\(safe).json")
    }

    private func lockURL(_ accountKey: String) -> URL {
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("pending-events-\(safe).lock")
    }

    public func append(_ events: [ThresholdEvent], accountKey: String) throws {
        guard !events.isEmpty else { return }
        let fileURL = url(accountKey)

        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            var merged: [EventIdentity: ThresholdEvent] = [:]
            for event in try loadUnlocked(from: fileURL) + events {
                let key = eventKey(event)
                merged[key] = merged[key].map { preferred($0, event) } ?? event
            }
            let ordered = merged.values.sorted {
                eventOrder($0, $1)
            }
            try writeUnlocked(capped(ordered, now: Date()), to: fileURL)
        }
    }

    /// Removes only events confirmed as scheduled. Events appended by another
    /// process while notification delivery is in progress remain queued. A
    /// newer event for the same reset segment also remains queued.
    public func acknowledge(
        _ delivered: [ThresholdEvent],
        accountKey: String
    ) throws {
        guard !delivered.isEmpty else { return }
        let fileURL = url(accountKey)
        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            let deliveredByKey = Dictionary(
                delivered.map { (eventKey($0), $0) },
                uniquingKeysWith: preferred
            )
            let remaining = try loadUnlocked(from: fileURL).filter { queued in
                guard let deliveredEvent = deliveredByKey[eventKey(queued)] else {
                    return true
                }
                return isNewer(queued, than: deliveredEvent)
            }
            if remaining.isEmpty {
                try PersistenceFileIO.removeIfPresent(at: fileURL)
            } else {
                try writeUnlocked(remaining, to: fileURL)
            }
        }
    }

    /// Returns the parked events and removes them. The read and delete happen
    /// under the same cross-process lock, so an append cannot be lost between
    /// those operations.
    public func drain(accountKey: String) throws -> [ThresholdEvent] {
        let fileURL = url(accountKey)
        return try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            let events = try loadUnlocked(from: fileURL)
            try PersistenceFileIO.removeIfPresent(at: fileURL)
            return events
        }
    }

    public func load(accountKey: String) throws -> [ThresholdEvent] {
        let fileURL = url(accountKey)
        return try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            try loadUnlocked(from: fileURL)
        }
    }

    public func delete(accountKey: String) throws {
        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            try PersistenceFileIO.removeIfPresent(at: url(accountKey))
        }
    }

    /// Removes the queue and its identifying lock file after the shared
    /// lifecycle registry has permanently tombstoned the account.
    public func deleteRetiredAccount(accountKey: String) throws {
        try delete(accountKey: accountKey)
        try PersistenceFileIO.removeIfPresent(at: lockURL(accountKey))
    }

    private func loadUnlocked(from fileURL: URL) throws -> [ThresholdEvent] {
        guard let data = try PersistenceFileIO.readIfPresent(at: fileURL) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ThresholdEvent].self, from: data)
        } catch {
            throw StorePersistenceError.corruptData(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func capped(_ events: [ThresholdEvent], now: Date) -> [ThresholdEvent] {
        let fresh = events.filter { event in
            guard let observed = event.observedAt else { return true }
            return now.timeIntervalSince(observed) <= Self.maximumEventAge
        }
        return Array(fresh.suffix(Self.maximumEventsPerAccount))
    }

    private func writeUnlocked(_ events: [ThresholdEvent], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var remaining = events
        while true {
            let data: Data
            do {
                data = try encoder.encode(remaining)
            } catch {
                throw StorePersistenceError.writeFailed(
                    path: fileURL.path,
                    reason: error.localizedDescription
                )
            }
            if data.count <= Self.maximumEncodedBytes {
                try PersistenceFileIO.writeAtomically(data, to: fileURL)
                return
            }
            guard !remaining.isEmpty else { return }
            remaining.removeFirst()
        }
    }

    private func eventKey(_ event: ThresholdEvent) -> EventIdentity {
        EventIdentity(
            windowId: event.windowId,
            threshold: event.threshold,
            resetSegment: event.resetSegment
        )
    }

    private func preferred(
        _ existing: ThresholdEvent,
        _ candidate: ThresholdEvent
    ) -> ThresholdEvent {
        isNewer(candidate, than: existing) ? candidate : existing
    }

    private func isNewer(
        _ candidate: ThresholdEvent,
        than existing: ThresholdEvent
    ) -> Bool {
        switch (candidate.observedAt, existing.observedAt) {
        case let (candidateDate?, existingDate?) where candidateDate != existingDate:
            return candidateDate > existingDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return candidate.utilization > existing.utilization
        }
    }

    private func eventOrder(_ lhs: ThresholdEvent, _ rhs: ThresholdEvent) -> Bool {
        if lhs.windowId != rhs.windowId { return lhs.windowId < rhs.windowId }
        if lhs.threshold != rhs.threshold { return lhs.threshold < rhs.threshold }
        let leftSegment = lhs.resetSegment ?? .min
        let rightSegment = rhs.resetSegment ?? .min
        if leftSegment != rightSegment { return leftSegment < rightSegment }
        return (lhs.observedAt ?? .distantPast) < (rhs.observedAt ?? .distantPast)
    }
}
