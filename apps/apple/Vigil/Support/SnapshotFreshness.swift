import Foundation
import VigilKit

/// The one staleness rule every glanceable surface shares (menu bar title,
/// home-screen widget, lock-screen widget): data older than 30 minutes is
/// stale, and a snapshot is degraded when it is stale or its last fetch did
/// not succeed. Failed fetches deliberately preserve the last good windows,
/// so honest freshness (docs/architecture.md) requires that degraded data
/// stays visible but never looks fresh.
enum SnapshotFreshness {
    /// Matches the widget timeline's re-fetch threshold and the menu bar
    /// title's warning threshold. Do not invent per-surface thresholds.
    static let staleAfter: TimeInterval = 30 * 60

    static func isStale(fetchedAt: Date, at now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > staleAfter
    }

    static func isDegraded(
        status: SnapshotStatus,
        fetchedAt: Date,
        at now: Date = Date()
    ) -> Bool {
        status != .ok || isStale(fetchedAt: fetchedAt, at: now)
    }
}
