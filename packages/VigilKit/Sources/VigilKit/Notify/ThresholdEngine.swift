import Foundation

public struct ThresholdEvent: Codable, Equatable, Sendable {
    public let windowId: String
    public let threshold: Int
    public let utilization: Double

    public init(windowId: String, threshold: Int, utilization: Double) {
        self.windowId = windowId
        self.threshold = threshold
        self.utilization = utilization
    }
}

/// Pure crossing detection — the app layer turns events into local
/// notifications. Keeping this side-effect-free makes it fully testable.
public enum ThresholdEngine {
    public static let defaultThresholds = [80, 95]

    /// Events fire when a window moves from below a threshold to at/above it
    /// between two consecutive snapshots. No previous snapshot -> no events
    /// (avoids a notification storm on first link). A window reset (usage
    /// dropping) never fires.
    ///
    /// A degraded `previous` (non-ok status) is still a valid baseline: failed
    /// fetches carry the last good windows forward, so a crossing that spans a
    /// blip (79 -> network error -> 81) must still fire. Only `current` needs
    /// to be fresh truth.
    public static func crossings(
        previous: ProviderSnapshot?,
        current: ProviderSnapshot,
        thresholds: [Int] = defaultThresholds
    ) -> [ThresholdEvent] {
        guard let previous, current.status == .ok else { return [] }
        // Provider-defined additional windows can repeat an ID or collide
        // with a built-in window. Never use uniqueKeysWithValues here because
        // duplicate untrusted IDs would trap the process. Mappers put primary
        // windows first, so preserving the first value also prevents an
        // additional lane from replacing the session or weekly baseline.
        var previousById: [String: UsageWindow] = [:]
        for window in previous.windows where previousById[window.id] == nil {
            previousById[window.id] = window
        }

        var events: [ThresholdEvent] = []
        var currentIDs = Set<String>()
        for window in current.windows where currentIDs.insert(window.id).inserted {
            guard let before = previousById[window.id] else { continue }
            guard window.utilization > before.utilization else { continue }
            for threshold in thresholds.sorted() {
                if before.utilization < Double(threshold), window.utilization >= Double(threshold) {
                    events.append(ThresholdEvent(windowId: window.id, threshold: threshold, utilization: window.utilization))
                }
            }
        }
        return events
    }
}
