import AppIntents
import Foundation
import OSLog
import VigilKit
import WidgetKit

struct WidgetAccount: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vigil Account")
    static var defaultQuery = WidgetAccountQuery()

    let id: String
    let providerId: String
    let label: String?
    let plan: String?
    let providerName: String

    init(_ account: AccountRef) {
        id = account.key
        providerId = account.providerId
        label = account.label
        plan = account.plan
        providerName = account.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        if let label, !label.isEmpty {
            return DisplayRepresentation(title: "\(providerName)", subtitle: "\(label)")
        }
        return DisplayRepresentation(title: "\(providerName)")
    }

    var accountRef: AccountRef {
        AccountRef(key: id, providerId: providerId, label: label, plan: plan)
    }
}

struct WidgetAccountQuery: EntityQuery {
    func entities(for identifiers: [WidgetAccount.ID]) async throws -> [WidgetAccount] {
        let wanted = Set(identifiers)
        return try AccountIndex.load()
            .filter { wanted.contains($0.key) }
            .map(WidgetAccount.init)
    }

    func suggestedEntities() async throws -> [WidgetAccount] {
        try AccountIndex.load().map(WidgetAccount.init)
    }

    func defaultResult() async -> WidgetAccount? {
        do {
            return try AccountIndex.load().first.map(WidgetAccount.init)
        } catch {
            Logger(subsystem: "app.vigil", category: "widget")
                .error("Could not load a default widget account: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return nil
        }
    }
}

struct SelectUsageAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Account"
    static var description = IntentDescription("Choose which linked account this widget monitors.")

    @Parameter(title: "Account")
    var account: WidgetAccount?
}

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
struct UsageTimelineProvider: AppIntentTimelineProvider {
    private static let log = Logger(subsystem: "app.vigil", category: "widget")
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

    func snapshot(for configuration: SelectUsageAccountIntent, in context: Context) async -> UsageEntry {
        let (account, snapshot) = Self.load(accountKey: configuration.account?.id)
        return UsageEntry(
            date: Date(),
            account: account,
            snapshot: snapshot ?? (context.isPreview ? Self.sampleSnapshot : nil)
        )
    }

    func timeline(for configuration: SelectUsageAccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        var (account, snapshot) = Self.load(accountKey: configuration.account?.id)

        if let account,
           (snapshot.map { Date().timeIntervalSince($0.fetchedAt) > Self.staleAfter } ?? true) {
            do {
                let vault = SharedKeychain.credentialsStore()
                if let credentials = try vault.load(accountKey: account.key) {
                    let result = await UsageService.refresh(
                        account: account,
                        credentials: credentials,
                        scheduler: Self.scheduler,
                        snapshots: SnapshotStore(directory: SharedContainer.directory),
                        vault: vault,
                        surface: "widget",
                        pendingEvents: PendingEventStore(directory: SharedContainer.directory)
                    )
                    if let fresh = result.snapshot { snapshot = fresh }
                    if let issue = result.persistenceIssue {
                        Self.log.error(
                            "Widget persistence failure: \(String(describing: issue), privacy: .private(mask: .hash))"
                        )
                    }
                } else {
                    Self.log.error(
                        "No credentials found for configured account \(account.key, privacy: .private(mask: .hash))"
                    )
                }
            } catch {
                Self.log.error(
                    "Could not load credentials for \(account.key, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        return Self.timeline(account: account, snapshot: snapshot)
    }

    // MARK: - Data

    private static func load(accountKey: String?) -> (AccountRef?, ProviderSnapshot?) {
        let accounts: [AccountRef]
        do {
            accounts = try AccountIndex.load()
        } catch {
            log.error(
                "Could not read account index: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (nil, nil)
        }

        // A removed configured account stays empty instead of silently
        // switching the widget to another user's account.
        let account = AccountIndex.selected(from: accounts, accountKey: accountKey)
        guard let account else { return (nil, nil) }
        do {
            let snapshot = try SnapshotStore(directory: SharedContainer.directory)
                .current(accountKey: account.key)
            return (account, snapshot)
        } catch {
            log.error(
                "Could not read snapshot for \(account.key, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (account, nil)
        }
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
            },
            metrics: snapshot.metrics
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
