import Foundation

/// Threshold crossings detected by a process that must not deliver
/// notifications itself (the widget extension) are parked here, in the shared
/// App Group container, until the app process drains and delivers them.
/// Events for the same window+threshold merge (keeping the highest
/// utilization) so repeated degraded fetches never stack duplicates.
public struct PendingEventStore: Sendable {
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
            var merged: [String: ThresholdEvent] = [:]
            for event in try loadUnlocked(from: fileURL) + events {
                let key = "\(event.windowId)#\(event.threshold)"
                if let existing = merged[key], existing.utilization >= event.utilization {
                    continue
                }
                merged[key] = event
            }
            let ordered = merged.values.sorted {
                ($0.windowId, $0.threshold) < ($1.windowId, $1.threshold)
            }
            try writeUnlocked(ordered, to: fileURL)
        }
    }

    /// Removes only events confirmed as scheduled. Events appended by another
    /// process while notification delivery is in progress remain queued. If a
    /// newer event for the same threshold has higher utilization, it also
    /// remains queued.
    public func acknowledge(
        _ delivered: [ThresholdEvent],
        accountKey: String
    ) throws {
        guard !delivered.isEmpty else { return }
        let fileURL = url(accountKey)
        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            let deliveredByKey = Dictionary(
                delivered.map { (eventKey($0), $0.utilization) },
                uniquingKeysWith: max
            )
            let remaining = try loadUnlocked(from: fileURL).filter { queued in
                guard let deliveredUtilization = deliveredByKey[eventKey(queued)] else {
                    return true
                }
                return queued.utilization > deliveredUtilization
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

    private func writeUnlocked(_ events: [ThresholdEvent], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(events)
        } catch {
            throw StorePersistenceError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        try PersistenceFileIO.writeAtomically(data, to: fileURL)
    }

    private func eventKey(_ event: ThresholdEvent) -> String {
        "\(event.windowId)#\(event.threshold)"
    }
}
