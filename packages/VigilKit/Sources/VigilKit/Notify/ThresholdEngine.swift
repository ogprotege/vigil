import Foundation

public struct ThresholdEvent: Codable, Equatable, Sendable {
    public let windowId: String
    public let threshold: Int
    public let utilization: Double
    /// Provider reading that proved the crossing. Older queue records omit it
    /// and are intentionally treated as unverifiable by the app.
    public let observedAt: Date?
    /// Reset boundary identifies the provider window segment when the provider
    /// exposes one. Some valid provider windows do not publish reset metadata.
    public let resetAt: Date?

    public init(
        windowId: String,
        threshold: Int,
        utilization: Double,
        observedAt: Date? = nil,
        resetAt: Date? = nil
    ) {
        self.windowId = windowId
        self.threshold = threshold
        self.utilization = utilization
        // SnapshotStore's ISO-8601 persistence has whole-second precision.
        // Matching that precision keeps widget-written events comparable with
        // the snapshot the app later reloads.
        self.observedAt = observedAt.map(Self.normalizedSecond)
        self.resetAt = resetAt.map(Self.normalizedSecond)
    }

    /// Stable reset-cycle identity used by the pending-event store. `nil`
    /// means the provider did not expose a reset boundary.
    public var resetSegment: Int64? {
        guard let resetAt else { return nil }
        return Int64(exactly: resetAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey {
        case windowId, threshold, utilization, observedAt, resetAt
    }

    /// Optional metadata keeps queues written by earlier Vigil versions
    /// decodable. A missing observation time identifies unverifiable legacy
    /// work. A missing reset time may instead be valid provider behavior.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowId: try values.decode(String.self, forKey: .windowId),
            threshold: try values.decode(Int.self, forKey: .threshold),
            utilization: try values.decode(Double.self, forKey: .utilization),
            observedAt: try values.decodeIfPresent(Date.self, forKey: .observedAt),
            resetAt: try values.decodeIfPresent(Date.self, forKey: .resetAt)
        )
    }

    private static func normalizedSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

public enum ThresholdEventDisposition: Equatable, Sendable {
    case actionable
    case unverifiable
    case expired
    case resetMismatch
    case noLongerCrossed
}

/// Pure crossing detection — the app layer turns events into local
/// notifications. Keeping this side-effect-free makes it fully testable.
public enum ThresholdEngine {
    public static let defaultThresholds = [80, 95]
    /// Matches the app and widget freshness contract. A notification that sat
    /// longer than one fresh-snapshot interval is no longer timely enough to
    /// interrupt the user.
    public static let maximumPendingAge: TimeInterval = 30 * 60

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
            if let beforeReset = before.resetsAt,
               let currentReset = window.resetsAt,
               beforeReset.timeIntervalSince1970.rounded(.down)
                != currentReset.timeIntervalSince1970.rounded(.down) {
                // A rising percentage in a new provider reset cycle is not a
                // crossing from the old cycle's baseline.
                continue
            }
            guard window.utilization > before.utilization else { continue }
            for threshold in thresholds.sorted() {
                if before.utilization < Double(threshold), window.utilization >= Double(threshold) {
                    events.append(
                        ThresholdEvent(
                            windowId: window.id,
                            threshold: threshold,
                            utilization: window.utilization,
                            observedAt: current.fetchedAt,
                            resetAt: window.resetsAt
                        )
                    )
                }
            }
        }
        return events
    }

    /// Revalidates a parked crossing against fresh provider truth immediately
    /// before notification delivery.
    public static func disposition(
        of event: ThresholdEvent,
        against current: ProviderSnapshot?,
        at now: Date = Date(),
        maximumAge: TimeInterval = maximumPendingAge
    ) -> ThresholdEventDisposition {
        guard maximumAge.isFinite, maximumAge > 0,
              now.timeIntervalSince1970.isFinite,
              event.threshold > 0,
              event.threshold <= 100,
              event.utilization.isFinite,
              event.utilization >= Double(event.threshold),
              let observedAt = event.observedAt,
              observedAt <= now,
              event.resetAt.map({ $0 > observedAt }) ?? true,
              event.resetAt == nil || event.resetSegment != nil
        else {
            return .unverifiable
        }
        guard now.timeIntervalSince(observedAt) <= maximumAge,
              event.resetAt.map({ $0 > now }) ?? true
        else {
            return .expired
        }
        guard let current,
              current.status == .ok,
              current.fetchedAt >= observedAt,
              current.fetchedAt <= now,
              now.timeIntervalSince(current.fetchedAt) <= maximumAge
        else {
            return .unverifiable
        }

        // Preserve mapper precedence when an untrusted provider repeats an ID.
        guard let window = current.windows.first(where: { $0.id == event.windowId }) else {
            return .unverifiable
        }
        if let eventSegment = event.resetSegment {
            guard let currentResetAt = window.resetsAt else {
                return .resetMismatch
            }
            guard let currentSegment = Int64(
                exactly: currentResetAt.timeIntervalSince1970.rounded(.down)
            ) else {
                return .resetMismatch
            }
            guard currentSegment == eventSegment else {
                return .resetMismatch
            }
        }
        guard window.utilization >= Double(event.threshold) else {
            return .noLongerCrossed
        }
        return .actionable
    }
}
