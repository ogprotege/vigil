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
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("pending-events-\(safe).json")
    }

    public func append(_ events: [ThresholdEvent], accountKey: String) {
        guard !events.isEmpty else { return }
        var merged: [String: ThresholdEvent] = [:]
        for event in load(accountKey: accountKey) + events {
            let key = "\(event.windowId)#\(event.threshold)"
            if let existing = merged[key], existing.utilization >= event.utilization { continue }
            merged[key] = event
        }
        let ordered = merged.values.sorted {
            ($0.windowId, $0.threshold) < ($1.windowId, $1.threshold)
        }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? data.write(to: url(accountKey), options: .atomic)
    }

    /// Returns the parked events and removes them.
    public func drain(accountKey: String) -> [ThresholdEvent] {
        let events = load(accountKey: accountKey)
        try? FileManager.default.removeItem(at: url(accountKey))
        return events
    }

    public func load(accountKey: String) -> [ThresholdEvent] {
        guard let data = try? Data(contentsOf: url(accountKey)) else { return [] }
        return (try? JSONDecoder().decode([ThresholdEvent].self, from: data)) ?? []
    }

    public func delete(accountKey: String) {
        try? FileManager.default.removeItem(at: url(accountKey))
    }
}
