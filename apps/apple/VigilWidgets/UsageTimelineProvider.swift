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
        id = OpaqueAccountIdentifier.widgetID(for: account.key)
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

}

struct WidgetAccountQuery: EntityQuery {
    func entities(for identifiers: [WidgetAccount.ID]) async throws -> [WidgetAccount] {
        let wanted = Set(identifiers)
        return try activeAccounts()
            .filter {
                wanted.contains(OpaqueAccountIdentifier.widgetID(for: $0.key))
                    || wanted.contains($0.key) // v1 configuration migration only
            }
            .map(WidgetAccount.init)
    }

    func suggestedEntities() async throws -> [WidgetAccount] {
        try activeAccounts().map(WidgetAccount.init)
    }

    func defaultResult() async -> WidgetAccount? {
        do {
            return try activeAccounts().first.map(WidgetAccount.init)
        } catch {
            Logger(subsystem: "app.vigil", category: "widget")
                .error("Could not load a default widget account: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return nil
        }
    }

    private func activeAccounts() throws -> [AccountRef] {
        let accounts = try AccountIndex.load()
        let statuses = try AccountLifecycleStore(
            directory: SharedContainer.directory
        ).statuses()
        return accounts.filter { statuses[$0.key] == .active }
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
    let appearance: VigilPreferences.Appearance
    let hidesUsageValues: Bool
}

/// Reads snapshots from the shared container with zero network; fetches only
/// when the snapshot is older than 5 minutes or a reset needs confirmation,
/// and only when the shared ledger allows (docs/architecture.md fetch
/// triggers). Timeline entries are scheduled at reset boundaries so the old
/// value is hidden until the next real fetch confirms the new window.
struct UsageTimelineProvider: AppIntentTimelineProvider {
    private static let log = Logger(subsystem: "app.vigil", category: "widget")
    private static let staleAfter: TimeInterval = 5 * 60

    /// One scheduler per widget process: preserves in-process single-flight
    /// across concurrent getTimeline calls (the cross-process budget lives in
    /// the shared ledger file either way).
    private static let scheduler = FetchScheduler(
        store: FileLedgerStore(directory: SharedContainer.directory)
    )

    func placeholder(in context: Context) -> UsageEntry {
        let preferences = Self.preferences()
        return UsageEntry(
            date: Date(),
            account: nil,
            snapshot: Self.sampleSnapshot,
            appearance: preferences.appearance,
            hidesUsageValues: preferences.widgetValuesHidden
        )
    }

    func snapshot(for configuration: SelectUsageAccountIntent, in context: Context) async -> UsageEntry {
        let preferences = Self.preferences()
        var (account, snapshot, generation) = Self.load(
            accountIdentifier: configuration.account?.id
        )
        if !Self.isStillCurrent(account: account, generation: generation) {
            account = nil
            snapshot = nil
            generation = nil
        }
        return UsageEntry(
            date: Date(),
            account: account,
            snapshot: snapshot ?? (context.isPreview ? Self.sampleSnapshot : nil),
            appearance: preferences.appearance,
            hidesUsageValues: preferences.widgetValuesHidden
        )
    }

    func timeline(for configuration: SelectUsageAccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        let preferences = Self.preferences()
        var (account, snapshot, generation) = Self.load(
            accountIdentifier: configuration.account?.id
        )
        var refreshAfter: Date?
        let now = Date()

        if !preferences.automaticChecksPaused,
           let selectedAccount = account,
           (snapshot.map {
               now.timeIntervalSince($0.fetchedAt) > Self.staleAfter
                   || SnapshotFreshness.hasUnconfirmedReset(in: $0, at: now)
           } ?? true) {
            do {
                let directory = SharedContainer.directory
                let lifecycle = AccountLifecycleStore(directory: directory)
                // The widget is a consumer of app-owned identity state. It
                // must never create lifecycle authority: a stale timeline
                // resuming after a full reset could otherwise resurrect the
                // departed account. Opening the app performs any legacy
                // register-if-missing upgrade before widgets fetch again.
                guard let generation else {
                    account = nil
                    snapshot = nil
                    return Self.timeline(
                        account: account,
                        snapshot: snapshot,
                        preferences: preferences
                    )
                }
                let vault = SharedKeychain.credentialsStore()
                let credentials = try lifecycle.withCurrentGeneration(
                    generation,
                    accountKey: selectedAccount.key
                ) {
                    try vault.load(accountKey: selectedAccount.key)
                }
                if let credentials {
                    let result = await UsageService.refresh(
                        account: selectedAccount,
                        credentials: credentials,
                        scheduler: Self.scheduler,
                        snapshots: SnapshotStore(directory: directory),
                        vault: vault,
                        surface: "widget",
                        emitThresholdEvents: preferences.usageAlertsEnabled,
                        pendingEvents: PendingEventStore(directory: directory),
                        history: UsageHistoryStore(directory: directory),
                        lifecycle: lifecycle,
                        generation: generation
                    )
                    let stillIndexed = (try? AccountIndex.load().contains {
                        $0.key == selectedAccount.key
                    }) == true
                    if try lifecycle.isCurrent(generation, accountKey: selectedAccount.key),
                       stillIndexed {
                        if let fresh = result.snapshot { snapshot = fresh }
                    } else {
                        account = nil
                        snapshot = nil
                    }
                    if let issue = result.persistenceIssue {
                        Self.log.error(
                            "Widget persistence failure: \(String(describing: issue), privacy: .private(mask: .hash))"
                        )
                    }
                    if let nextAllowed = result.nextAllowed {
                        refreshAfter = nextAllowed
                    } else {
                        refreshAfter = await Self.scheduler.nextAllowedFetch(
                            accountKey: selectedAccount.key
                        )
                    }
                } else {
                    Self.log.error(
                        "No credentials found for configured account \(selectedAccount.key, privacy: .private(mask: .hash))"
                    )
                }
            } catch {
                Self.log.error(
                    "Could not load credentials for \(selectedAccount.key, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        // Always revalidate the exact generation captured while loading, even
        // when the snapshot was fresh and no network await occurred. A reset
        // or remove/re-link that wins after load must not let this invocation
        // submit its old account and snapshot to WidgetKit.
        if !Self.isStillCurrent(account: account, generation: generation) {
            account = nil
            snapshot = nil
            generation = nil
        }

        return Self.timeline(
            account: account,
            snapshot: snapshot,
            refreshAfter: refreshAfter,
            preferences: preferences
        )
    }

    // MARK: - Data

    private static func load(
        accountIdentifier: String?
    ) -> (AccountRef?, ProviderSnapshot?, AccountLifecycleGeneration?) {
        let accounts: [AccountRef]
        do {
            accounts = try AccountIndex.load()
        } catch {
            log.error(
                "Could not read account index: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (nil, nil, nil)
        }

        // A removed configured account stays empty instead of silently
        // switching the widget to another user's account.
        let account = AccountIndex.selectedForWidget(
            from: accounts,
            identifier: accountIdentifier
        )
        guard let account else { return (nil, nil, nil) }
        do {
            let directory = SharedContainer.directory
            let lifecycle = AccountLifecycleStore(directory: directory)
            guard let generation = try lifecycle.captureActiveGeneration(
                accountKey: account.key
            ) else {
                return (nil, nil, nil)
            }
            let snapshot = try lifecycle.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try SnapshotStore(directory: directory).current(accountKey: account.key)
            }
            return (account, snapshot, generation)
        } catch {
            log.error(
                "Could not read snapshot for \(account.key, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return (account, nil, nil)
        }
    }

    private static func isStillCurrent(
        account: AccountRef?,
        generation: AccountLifecycleGeneration?
    ) -> Bool {
        guard let account, let generation else { return false }
        do {
            let directory = SharedContainer.directory
            let lifecycle = AccountLifecycleStore(directory: directory)
            guard try lifecycle.isCurrent(generation, accountKey: account.key) else {
                return false
            }
            return try AccountIndex.load().contains { $0.key == account.key }
        } catch {
            log.error(
                "Could not revalidate widget account: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    private static func timeline(
        account: AccountRef?,
        snapshot: ProviderSnapshot?,
        refreshAfter: Date? = nil,
        preferences: VigilPreferences
    ) -> Timeline<UsageEntry> {
        let now = Date()
        var entries = [UsageEntry(
            date: now,
            account: account,
            snapshot: snapshot,
            appearance: preferences.appearance,
            hidesUsageValues: preferences.widgetValuesHidden
        )]

        var reloadAt = now.addingTimeInterval(
            preferences.automaticChecksPaused ? 60 * 60 : staleAfter
        )
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
                    snapshot: snapshot,
                    appearance: preferences.appearance,
                    hidesUsageValues: preferences.widgetValuesHidden
                ))
                reloadAt = min(reloadAt, at)
            }
        }
        if let refreshAfter, refreshAfter > now {
            reloadAt = min(reloadAt, refreshAfter.addingTimeInterval(1))
        }

        // Ask WidgetKit for a new timeline at the first reset or ledger retry,
        // while retaining the ordinary 5-minute upper bound.
        return Timeline(entries: entries, policy: .after(reloadAt))
    }

    private static func preferences() -> VigilPreferences {
        VigilPreferences(defaults: SharedContainer.preferencesDefaults)
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
