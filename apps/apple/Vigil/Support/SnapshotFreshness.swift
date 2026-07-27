import Foundation
import VigilKit

/// The one staleness rule every glanceable surface shares (app rows,
/// home-screen widget, lock-screen widget): data older than 30 minutes is
/// stale, and a snapshot is degraded when it is stale or its last fetch did
/// not succeed. Failed fetches deliberately preserve the last good windows,
/// so honest freshness (docs/architecture.md) requires that degraded data
/// stays visible but never looks fresh.
enum SnapshotFreshness {
    /// Matches the widget timeline's re-fetch threshold and the app's warning
    /// threshold. Do not invent per-surface thresholds.
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

    /// A provider reset boundary invalidates the old reading for that window.
    /// It does not prove the new utilization is zero. Glanceable surfaces must
    /// hide that pre-reset value until a provider fetch confirms the new one.
    static func resetIsUnconfirmed(
        for window: UsageWindow,
        fetchedAt: Date,
        at now: Date = Date()
    ) -> Bool {
        guard let resetsAt = window.resetsAt else { return false }
        return resetsAt > fetchedAt && resetsAt <= now
    }

    static func hasUnconfirmedReset(
        in snapshot: ProviderSnapshot,
        at now: Date = Date()
    ) -> Bool {
        snapshot.windows.contains {
            resetIsUnconfirmed(for: $0, fetchedAt: snapshot.fetchedAt, at: now)
        }
    }

    static func confirmedWindows(
        in snapshot: ProviderSnapshot,
        at now: Date = Date()
    ) -> [UsageWindow] {
        snapshot.windows.filter {
            !resetIsUnconfirmed(for: $0, fetchedAt: snapshot.fetchedAt, at: now)
        }
    }
}
