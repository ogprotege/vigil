import Foundation
import VigilKit
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let account: AccountRef?
    let snapshot: ProviderSnapshot?
}

/// Reads snapshots from the shared container with zero network; fetches only
/// when the snapshot is older than 30 minutes AND the shared ledger allows
/// (docs/architecture.md fetch triggers). Timeline entries are scheduled at
/// reset boundaries so a window visually drops to ~0% on time even before the
/// next real fetch confirms it.
struct UsageTimelineProvider: TimelineProvider {
    private static let staleAfter: TimeInterval = 30 * 60

    /// One scheduler per widget process: preserves in-process single-flight
    /// across concurrent getTimeline calls (the cross-process budget lives in
    /// the shared ledger file either way).
    private static let scheduler = FetchScheduler(
        store: FileLedgerStore(directory: SharedContainer.directory)
    )

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), account: nil, snapshot: Self.sampleSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let (account, snapshot) = Self.load()
        completion(UsageEntry(
            date: Date(),
            account: account,
            snapshot: snapshot ?? (context.isPreview ? Self.sampleSnapshot : nil)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            var (account, snapshot) = Self.load()

            if let account,
               let credentials = try? KeychainCredentialsStore().load(accountKey: account.key),
               (snapshot.map { Date().timeIntervalSince($0.fetchedAt) > Self.staleAfter } ?? true) {
                let result = await UsageService.refresh(
                    account: account,
                    credentials: credentials,
                    scheduler: Self.scheduler,
                    snapshots: SnapshotStore(directory: SharedContainer.directory),
                    vault: KeychainCredentialsStore(),
                    surface: "widget"
                )
                if let fresh = result.snapshot { snapshot = fresh }
            }

            completion(Self.timeline(account: account, snapshot: snapshot))
        }
    }

    // MARK: - Data

    private static func load() -> (AccountRef?, ProviderSnapshot?) {
        guard let account = AccountIndex.load().first else { return (nil, nil) }
        let snapshot = SnapshotStore(directory: SharedContainer.directory)
            .current(accountKey: account.key)
        return (account, snapshot)
    }

    private static func timeline(account: AccountRef?, snapshot: ProviderSnapshot?) -> Timeline<UsageEntry> {
        let now = Date()
        // The first entry is reset-adjusted too: after a boundary passes, a
        // reloaded timeline must not regress to the pre-reset percentage.
        var entries = [UsageEntry(
            date: now,
            account: account,
            snapshot: snapshot.map { applyingResets(to: $0, at: now) }
        )]

        if let snapshot {
            let boundaries = snapshot.windows
                .compactMap(\.resetsAt)
                .filter { $0 > now }
                .sorted()
                .prefix(4)
            for boundary in boundaries {
                let at = boundary.addingTimeInterval(1)
                entries.append(UsageEntry(
                    date: at,
                    account: account,
                    snapshot: Self.applyingResets(to: snapshot, at: at)
                ))
            }
        }

        // Re-evaluate the fetch rule every 30 minutes; boundary entries handle
        // visual resets in between with zero network.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(staleAfter)))
    }

    /// A window whose reset has passed renders at ~0% until the next real
    /// fetch confirms it (mac-checklist §M5 step 13).
    private static func applyingResets(to snapshot: ProviderSnapshot, at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: snapshot.providerId,
            accountKey: snapshot.accountKey,
            accountLabel: snapshot.accountLabel,
            planLabel: snapshot.planLabel,
            fetchedAt: snapshot.fetchedAt,
            status: snapshot.status,
            windows: snapshot.windows.map { window in
                guard let resetsAt = window.resetsAt, resetsAt <= date,
                      // Clock-skew guard: only zero a window whose reset is
                      // genuinely later than the data itself — a resetsAt at
                      // or before fetchedAt would fabricate 0% over fresh data.
                      resetsAt > snapshot.fetchedAt
                else { return window }
                return UsageWindow(
                    id: window.id,
                    utilization: 0,
                    resetsAt: nil,
                    windowSeconds: window.windowSeconds,
                    secondary: window.secondary
                )
            }
        )
    }

    private static var sampleSnapshot: ProviderSnapshot {
        ProviderSnapshot(
            providerId: "claude",
            accountKey: "claude:sample",
            accountLabel: "Claude (max)",
            planLabel: "max",
            fetchedAt: Date(),
            status: .ok,
            windows: [
                UsageWindow(id: "session", utilization: 42, resetsAt: Date().addingTimeInterval(4500), windowSeconds: 18_000, secondary: false),
                UsageWindow(id: "weekly", utilization: 61, resetsAt: Date().addingTimeInterval(200_000), windowSeconds: 604_800, secondary: false),
            ]
        )
    }
}
