import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import VigilKit
#if canImport(WidgetKit)
import WidgetKit
#endif

enum OfficialHistoryImportState: Equatable {
    case idle
    case importing
    case imported(sampleCount: Int, at: Date)
    case failed(String)
}

/// Serializes AppModel's archive reads, migration, and destructive whole-store
/// recovery away from the main actor. SQLite coordinates ordinary concurrent
/// row mutations itself, but deleting the database files must not overlap an
/// AppModel read that still owns a database descriptor. Every operation runs
/// under a suspension guard: the history flock and SQLite WAL locks held
/// during I/O get the process killed (0xdead10cc) if it is suspended mid-lock.
private actor AppHistoryIOCoordinator {
    func perform<Value: Sendable>(
        _ operation: @Sendable () throws -> Value
    ) rethrows -> Value {
        try SuspensionGuard.withProtection(named: "HistoryIO") {
            try operation()
        }
    }
}

/// Root observable state: linked accounts, their snapshots, and the shared
/// fetch pipeline. All fetches, including the foreground timer, pull-to-refresh,
/// background task, and widgets, go through UsageService and the shared ledger.
@MainActor
@Observable
final class AppModel {
    private static let log = Logger(subsystem: "app.vigil", category: "model")
    private(set) var accounts: [AccountRef] = []
    private(set) var snapshots: [String: ProviderSnapshot] = [:]
    /// Ledger-imposed earliest next fetch per account (for "next check at").
    private(set) var nextAllowed: [String: Date] = [:]
    /// A visible, dismissible storage failure. Persistence failures must never
    /// be reduced to a log line because that can make the UI claim data is
    /// durable when it is not.
    private(set) var storageErrorMessage: String?
    private(set) var accountIndexUsable = true
    private(set) var hasAccountRepairBackups = false
    /// A fail-closed identity error cannot be guessed around safely. Settings
    /// exposes an explicit, confirmed full local reset while this is true.
    private(set) var requiresFullLocalDataRecovery = false
    private(set) var isResettingAllLocalData = false
    /// True when launched with `VIGIL_DEMO=1` (screenshot tooling only). In demo
    /// mode the accounts are seeded in memory and never fetched, so the seeded
    /// snapshots aren't overwritten by auth failures (there are no credentials).
    private(set) var isDemo = false
    /// Constant-size history metadata plus a small recent preview. The full
    /// archive stays in SQLite and is read only through cursor-paged queries.
    private(set) var historySummaries: [String: AccountHistorySummary] = [:]
    private(set) var recentHistorySamples: [String: [UsageHistorySample]] = [:]
    private(set) var officialHistoryImports: [String: OfficialHistoryImportState] = [:]

    let vault: any CredentialsStore
    let scheduler: FetchScheduler
    let snapshotStore: SnapshotStore
    let historyStore: UsageHistoryStore
    let pendingEvents: PendingEventStore
    let lifecycleStore: AccountLifecycleStore
    let notifications: any NotificationManaging
    private let accountIndexURL: URL
    private let fullRecoveryDirectories: [URL]
    private let legacyObservationStore: LegacyUsageObservationStore
    private let historyIO = AppHistoryIOCoordinator()
    private let usageSession: URLSession
    private var lifecycleUsable = true
    private struct StorageNotice {
        let message: String
        let priority: Int
    }
    private var storageErrorPriority = 0
    private var pendingStorageNotices: [StorageNotice] = []

    /// Stored (not computed) so @Observable tracking sees changes; persisted
    /// to UserDefaults as a side effect.
    var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "app.vigil.lockEnabled") }
    }

    private var foregroundTimer: Task<Void, Never>?
    private var historyReloadRevision = 0
    /// Startup reconciliation may need an async notification/ledger tail after
    /// it has removed a tombstoned account from the visible index. Re-linking
    /// the same key is blocked until that tail finishes so an old raw-key clear
    /// cannot erase the new lifecycle's poll state or notifications.
    private var retiringAccountKeys = Set<String>()
    /// Main-actor ownership gate for explicit removals. One caller owns all
    /// destructive work for an account key until every awaited cleanup step
    /// returns. This also quarantines same-key linking during that interval.
    private(set) var removingAccountKeys = Set<String>()
    /// Invalidates identity mutations that were suspended while a confirmed
    /// full local reset ran. The lifecycle generation protects existing
    /// accounts; this epoch also covers a brand-new add still in verification
    /// before any lifecycle entry exists.
    private var identityMutationEpoch: UInt64 = 0
    private var destructiveCleanupCount = 0
    private var destructiveCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    /// Full recovery must not return while an older threshold delivery can
    /// still be accepted by Notification Center. The reset blocks new drains,
    /// waits for this count to reach zero, then performs a final owned-ID
    /// sweep before exposing the empty setup state.
    private var notificationDeliveryCount = 0
    private var notificationDeliveryWaiters: [CheckedContinuation<Void, Never>] = []

    struct AccountHistorySummary: Equatable, Sendable {
        let all: UsageHistorySummary
        let observed: UsageHistorySummary
        let providerBackfill: UsageHistorySummary

        func summary(for source: UsageHistorySource) -> UsageHistorySummary {
            switch source {
            case .observed: observed
            case .providerBackfill: providerBackfill
            }
        }
    }

    private struct LoadedHistoryState: Sendable {
        let summaries: [String: AccountHistorySummary]
        let recent: [String: [UsageHistorySample]]
    }

    private static let recentHistoryPreviewCount = 8
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    init(
        vault: (any CredentialsStore)? = nil,
        directory: URL = SharedContainer.directory,
        notifications: any NotificationManaging = NotificationManager(),
        usageSession: URLSession = ProviderUsageSession.shared,
        scheduler: FetchScheduler? = nil,
        additionalRecoveryDirectories: [URL] = []
    ) {
        self.vault = vault ?? SharedKeychain.credentialsStore()
        self.scheduler = scheduler
            ?? FetchScheduler(store: FileLedgerStore(directory: directory))
        self.snapshotStore = SnapshotStore(directory: directory)
        self.historyStore = UsageHistoryStore(directory: directory)
        self.pendingEvents = PendingEventStore(directory: directory)
        self.lifecycleStore = AccountLifecycleStore(directory: directory)
        self.notifications = notifications
        self.usageSession = usageSession
        self.accountIndexURL = directory.appendingPathComponent("account-index.json")
        let discoveredRecoveryDirectories = Self.isRunningUnitTests
            ? [directory]
            : SharedContainer.recoveryDirectories(current: directory)
        var seenRecoveryPaths = Set<String>()
        self.fullRecoveryDirectories = (discoveredRecoveryDirectories
            + additionalRecoveryDirectories).filter {
                seenRecoveryPaths.insert($0.standardizedFileURL.path).inserted
            }
        self.legacyObservationStore = LegacyUsageObservationStore(directory: directory)
        self.lockEnabled = UserDefaults.standard.bool(forKey: "app.vigil.lockEnabled")
        // Builds through 0.14 used URLSession.shared for provider and token
        // exchange traffic. The current ephemeral session cannot read that
        // storage, and this app-scoped cleanup removes any response or cookie
        // residue left by an older install. It never touches Safari or the
        // browser session used to approve OAuth.
        LegacyNetworkStorageCleaner.removeAppScopedSharedSessionData()
        loadFromDisk()
        let notificationManager = self.notifications
        Task { await notificationManager.removeLegacyNotifications() }
        surfaceSharedStorageFallbackIfNeeded()
        seedDemoDataIfRequested()
    }

    /// Screenshot tooling: with `VIGIL_DEMO=1`, replace the (empty on a fresh
    /// install) in-memory state with representative sample data. Nothing is
    /// written to disk and no fetch runs, so this cannot leak into real usage.
    private func seedDemoDataIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard DemoData.requested(in: environment) else { return }
        isDemo = true
        let claudeStatus: SnapshotStatus = DemoData.claudeAuthExpiredRequested(in: environment)
            ? .authExpired
            : .ok
        let demo = DemoData.seed(claudeStatus: claudeStatus)
        accounts = demo.accounts
        snapshots = demo.snapshots
    }

    /// The App Group container being unavailable silently disables the
    /// cross-process no-double-poll guarantee — surface it once at startup
    /// through the same storage-error path as every other persistence
    /// failure. App-process only: XCTest and previews build models against
    /// temporary directories where the fallback is expected, and the widget
    /// process cannot present UI (SharedContainer already logs there).
    private func surfaceSharedStorageFallbackIfNeeded() {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              !DemoData.requested(in: ProcessInfo.processInfo.environment),
              SharedContainer.isUsingFallbackStorage
        else { return }
        reportStorageError(
            "Vigil couldn't open its shared App Group storage and is using app-private storage instead. The app and its widgets can't share the polling ledger, so each may poll providers separately. This usually indicates a signing or entitlement problem — reinstalling Vigil may fix it.",
            priority: 3
        )
    }

    /// Instant render on relaunch: accounts + last snapshots, zero network.
    func loadFromDisk() {
        var sourceAccounts: [AccountRef]
        var repairedCorruptIndex = false
        var corruptIndexError: Error?
        do {
            sourceAccounts = try AccountIndex.load(from: accountIndexURL)
        } catch {
            do {
                sourceAccounts = try recoverAccountsFromKeychain()
                _ = try AccountIndex.preserveCorruptFile(at: accountIndexURL)
                repairedCorruptIndex = true
                corruptIndexError = error
            } catch let recoveryError {
                accounts = []
                accountIndexUsable = false
                requiresFullLocalDataRecovery = true
                reportStorageError(
                    "Vigil couldn't read or safely recover its account index. Linking and removal are blocked so existing Keychain references are not overwritten. Settings can erase all local Vigil data and start over.",
                    error: recoveryError,
                    priority: 4
                )
                return
            }
        }

        let reconciliation: AccountReconciliation
        do {
            reconciliation = try reconcileAccounts(sourceAccounts)
            if repairedCorruptIndex || reconciliation.changed {
                try AccountIndex.save(reconciliation.accounts, to: accountIndexURL)
            }
            accounts = reconciliation.accounts
            accountIndexUsable = true
            requiresFullLocalDataRecovery = false
        } catch {
            accounts = sourceAccounts
            accountIndexUsable = false
            requiresFullLocalDataRecovery = true
            reportStorageError(
                "Vigil couldn't reconcile its account list with Keychain and the shared lifecycle registry. Linking and removal are blocked so no credential is hidden or overwritten. Settings can erase all local Vigil data and start over.",
                error: error,
                priority: 4
            )
            return
        }

        if repairedCorruptIndex {
            let message = accounts.isEmpty
                ? "Vigil rebuilt an empty account list because no active Keychain credentials remained. A damaged-index repair backup is available to delete in Settings."
                : "Vigil repaired its damaged account index from Keychain. Review the recovered accounts, then delete the damaged-index repair backup in Settings."
            reportStorageError(
                message,
                error: corruptIndexError,
                priority: 4
            )
        } else if reconciliation.recoveredCount > 0 {
            reportStorageError(
                "Vigil recovered \(reconciliation.recoveredCount) account \(reconciliation.recoveredCount == 1 ? "credential" : "credentials") that survived an interrupted link or reinstall. Review the recovered account list.",
                priority: 3
            )
        }
        if reconciliation.incompleteRemovalCount > 0 {
            reportStorageError(
                "Vigil found an interrupted account removal but couldn't finish deleting all local account data. It kept that account blocked from re-linking and visible when possible; relaunch to retry cleanup.",
                priority: 3
            )
        }
        do {
            let keysToKeep = Set(reconciliation.accounts.map(\.key))
                .union(reconciliation.blockedRetirementKeys)
            let result = try OrphanedAccountStatePruner.prune(
                directory: accountIndexURL.deletingLastPathComponent(),
                keepingAccountKeys: keysToKeep
            )
            if result.ledgerEntriesRemoved > 0 || result.lockFilesRemoved > 0 {
                Self.log.info(
                    "Removed \(result.ledgerEntriesRemoved, privacy: .public) orphaned polling rows and \(result.lockFilesRemoved, privacy: .public) account lock files from an earlier app version"
                )
            }
        } catch {
            reportStorageError(
                "Vigil couldn't clean up polling metadata left by an earlier account removal. A re-linked account may wait for the prior polling floor to expire.",
                error: error,
                priority: 2
            )
        }
        do {
            hasAccountRepairBackups = try AccountIndex.hasCorruptBackups(
                in: accountIndexURL.deletingLastPathComponent()
            )
        } catch {
            reportStorageError(
                "Vigil couldn't inspect its account-index repair backups.",
                error: error,
                priority: 2
            )
        }

        var loaded: [String: ProviderSnapshot] = [:]
        for account in accounts {
            do {
                loaded[account.key] = try snapshotStore.current(accountKey: account.key)
            } catch {
                reportStorageError(
                    "Vigil couldn't read the saved usage for \(account.displayName). It will not overwrite the damaged snapshot.",
                    error: error
                )
            }
        }
        snapshots = loaded
        registerExistingAccountLifecycles()
        prepareHistoryState()
        // Hydrate poll clocks so Home can tell the truth before the first tap.
        Task { await hydrateNextAllowed() }
        retiringAccountKeys.formUnion(reconciliation.blockedRetirementKeys)
        if !reconciliation.retiredAccountKeys.isEmpty {
            let retiredAccountKeys = reconciliation.retiredAccountKeys
            let scheduledEpoch = identityMutationEpoch
            Task { [weak self] in
                await self?.finishStartupRetirements(
                    retiredAccountKeys,
                    scheduledEpoch: scheduledEpoch
                )
            }
        }
    }

    private struct AccountReconciliation {
        let accounts: [AccountRef]
        let retiredAccountKeys: [String]
        let blockedRetirementKeys: [String]
        let recoveredCount: Int
        let incompleteRemovalCount: Int
        let changed: Bool
    }

    /// Reconciles all three durable identity surfaces on every launch. This is
    /// the crash-recovery transaction for both linking and removal:
    ///
    /// - an active Keychain item missing from a valid index is made visible;
    /// - a tombstoned item is deleted rather than resurrected; and
    /// - a tombstone with no remaining Keychain item still finishes cleanup.
    private func reconcileAccounts(_ indexedAccounts: [AccountRef]) throws -> AccountReconciliation {
        let indexedByKey = Dictionary(
            indexedAccounts.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let credentialKeys = Set(try vault.allKeys())
        var lifecycleStatuses = try lifecycleStore.statuses()
        let allKeys = Set(indexedByKey.keys)
            .union(credentialKeys)
            .union(lifecycleStatuses.keys)
            .sorted()

        var reconciledByKey = indexedByKey
        var retiredAccountKeys: [String] = []
        var blockedRetirementKeys: [String] = []
        var recoveredCount = 0
        var incompleteRemovalCount = 0

        for accountKey in allKeys {
            let indexed = indexedByKey[accountKey]
            let hasCredential = credentialKeys.contains(accountKey)
            let status = lifecycleStatuses[accountKey]

            if status == .tombstoned {
                blockedRetirementKeys.append(accountKey)
                do {
                    if hasCredential {
                        try vault.delete(accountKey: accountKey)
                    }
                    try deleteRetiredLocalState(accountKey: accountKey)
                    reconciledByKey[accountKey] = nil
                    retiredAccountKeys.append(accountKey)
                } catch {
                    incompleteRemovalCount += 1
                    reportStorageError(
                        "Vigil couldn't finish an interrupted account removal. It kept the account visible when possible so removal can be retried.",
                        error: error,
                        priority: 3
                    )
                }
                continue
            }

            if let indexed {
                // Upgrade path for accounts created before lifecycle tracking.
                if status == nil {
                    _ = try lifecycleStore.registerIfMissing(accountKey: accountKey)
                    lifecycleStatuses[accountKey] = .active
                }
                reconciledByKey[accountKey] = indexed
                continue
            }

            guard hasCredential else {
                // A crash immediately after lifecycle creation but before the
                // credential write leaves no user data to recover.
                if status == .active {
                    _ = try lifecycleStore.removeEntry(
                        accountKey: accountKey,
                        ifStatus: .active
                    )
                }
                continue
            }

            guard let credentials = try vault.load(accountKey: accountKey) else {
                throw AccountIndexRecoveryError.missingCredential
            }
            if status == nil {
                _ = try lifecycleStore.beginNewLifecycle(accountKey: accountKey)
                lifecycleStatuses[accountKey] = .active
            }
            reconciledByKey[accountKey] = AccountRef(
                key: accountKey,
                providerId: credentials.providerId,
                label: credentials.label,
                plan: credentials.plan
            )
            recoveredCount += 1
        }

        // Preserve the user's prior ordering and append only recovered rows in
        // deterministic key order.
        let retained = indexedAccounts.compactMap { reconciledByKey.removeValue(forKey: $0.key) }
        let recovered = reconciledByKey.values.sorted { $0.key < $1.key }
        let result = retained + recovered
        return AccountReconciliation(
            accounts: result,
            retiredAccountKeys: retiredAccountKeys,
            blockedRetirementKeys: blockedRetirementKeys,
            recoveredCount: recoveredCount,
            incompleteRemovalCount: incompleteRemovalCount,
            changed: result != indexedAccounts
        )
    }

    private func deleteRetiredLocalState(accountKey: String) throws {
        try snapshotStore.deleteRetiredAccount(accountKey: accountKey)
        try pendingEvents.deleteRetiredAccount(accountKey: accountKey)
        try legacyObservationStore.removeAll(accountKey: accountKey)
        try SuspensionGuard.withProtection(named: "HistoryDelete") {
            try historyStore.delete(accountKey: accountKey)
        }
        try AccountIndex.deleteCorruptBackups(
            in: accountIndexURL.deletingLastPathComponent()
        )
    }

    private func finishStartupRetirements(
        _ accountKeys: [String],
        scheduledEpoch: UInt64
    ) async {
        guard scheduledEpoch == identityMutationEpoch else { return }
        guard let cleanupEpoch = try? beginDestructiveCleanup() else { return }
        defer { finishDestructiveCleanup() }
        for accountKey in accountKeys {
            await notifications.removeNotifications(accountKey: accountKey)
            guard destructiveCleanupIsCurrent(cleanupEpoch) else { return }
            let ledgerCleared = await scheduler.clear(accountKey: accountKey)
            guard destructiveCleanupIsCurrent(cleanupEpoch) else { return }
            guard ledgerCleared else {
                let detail = await scheduler.persistenceErrorDescription(accountKey: accountKey)
                reportStorageError(
                    "Vigil removed an interrupted account but couldn't clear its polling metadata. It will retry on the next launch.",
                    error: detail.map { AccountRetirementError.ledger($0) },
                    priority: 2
                )
                continue
            }
            do {
                _ = try lifecycleStore.removeEntry(
                    accountKey: accountKey,
                    ifStatus: .tombstoned
                )
                retiringAccountKeys.remove(accountKey)
            } catch {
                reportStorageError(
                    "Vigil removed an interrupted account but couldn't prune its retired lifecycle metadata. It will retry on the next launch.",
                    error: error,
                    priority: 2
                )
            }
        }
    }

    private enum AccountRetirementError: LocalizedError {
        case ledger(String)

        var errorDescription: String? {
            switch self {
            case .ledger(let detail):
                return detail
            }
        }
    }

    private func registerExistingAccountLifecycles() {
        do {
            for account in accounts {
                _ = try lifecycleStore.registerIfMissing(accountKey: account.key)
            }
            lifecycleUsable = true
        } catch {
            lifecycleUsable = false
            requiresFullLocalDataRecovery = true
            reportStorageError(
                "Vigil couldn't validate its shared account lifecycle registry. Linking, removal, and provider writes are blocked to protect removed accounts. Settings can erase all local Vigil data and start over.",
                error: error,
                priority: 4
            )
        }
    }

    /// One-time bridge from the retired money-only log. Stable legacy UUIDs
    /// make retries idempotent if the app stops after import but before file
    /// deletion. An unreadable or partially migrated file stays in place.
    /// History migration and SQLite reads can be substantial on upgrade. Keep
    /// both away from the main actor, then publish only summaries and a small
    /// per-source preview to observable UI state.
    private func prepareHistoryState() {
        guard accountIndexUsable, lifecycleUsable else { return }
        // App-hosted unit tests own short-lived temporary directories. An
        // unstructured startup task can outlive the test method and keep a
        // SQLite vnode open while XCTest removes that directory. Tests invoke
        // the awaitable hook below when startup migration is under test. The
        // shipping app still performs this work off the main actor.
        guard !Self.isRunningUnitTests else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.migrateLegacyObservationsIfNeeded()
            await self.reloadHistoryState()
        }
    }

    /// Deterministic unit-test boundary for startup migration. Kept internal
    /// through `@testable import`; production surfaces use prepareHistoryState.
    func prepareHistoryStateForTesting() async {
        guard Self.isRunningUnitTests, accountIndexUsable, lifecycleUsable else { return }
        await migrateLegacyObservationsIfNeeded()
        await reloadHistoryState()
    }

    private func migrateLegacyObservationsIfNeeded() async {
        let legacyStore = legacyObservationStore
        let historyStore = historyStore
        let lifecycleStore = lifecycleStore
        let activeAccounts = accounts
        do {
            try await historyIO.perform {
                guard legacyStore.exists else { return }
                try legacyStore.migrate(
                    to: historyStore,
                    activeAccounts: activeAccounts,
                    lifecycleStore: lifecycleStore
                )
            }
        } catch {
            reportStorageError(
                "Vigil couldn't migrate its earlier observed money history. The legacy file was preserved and Vigil will retry after relaunch.",
                error: error,
                priority: 2
            )
        }
    }

    private func queueHistoryReload() {
        Task { [weak self] in
            await self?.reloadHistoryState()
        }
    }

    /// Reconciles the cross-process history without decoding the full archive.
    /// One extra row per source lets the preview identify the previous reset
    /// segment without presenting more than eight visible readings.
    private func reloadHistoryState() async {
        historyReloadRevision += 1
        let revision = historyReloadRevision
        let targets: [(account: AccountRef, generation: AccountLifecycleGeneration)]
        do {
            targets = try accounts.compactMap { account in
                guard let generation = try lifecycleStore.captureActiveGeneration(
                    accountKey: account.key
                ) else { return nil }
                return (account, generation)
            }
        } catch {
            reportStorageError(
                "Vigil couldn't validate accounts before reading protected quota history.",
                error: error,
                priority: 3
            )
            return
        }

        let store = historyStore
        let keys = targets.map { $0.account.key }
        let previewLimit = Self.recentHistoryPreviewCount + 1
        let loaded: LoadedHistoryState
        do {
            loaded = try await historyIO.perform {
                var summaries: [String: AccountHistorySummary] = [:]
                var recent: [String: [UsageHistorySample]] = [:]
                for key in keys {
                    // One connection per account: the summaries and both
                    // preview pages share a single flock acquisition and a
                    // single checkpointed close instead of five.
                    let state = try store.accountState(
                        accountKey: key,
                        previewLimit: previewLimit
                    )
                    summaries[key] = AccountHistorySummary(
                        all: state.all,
                        observed: state.observed,
                        providerBackfill: state.providerBackfill
                    )
                    recent[key] = (
                        state.observedPage.samples + state.providerBackfillPage.samples
                    ).sorted {
                        ($0.recordedAt, $0.retrievedAt, $0.id.uuidString)
                            < ($1.recordedAt, $1.retrievedAt, $1.id.uuidString)
                    }
                }
                return LoadedHistoryState(summaries: summaries, recent: recent)
            }
        } catch {
            reportStorageError(
                "Vigil couldn't read its protected quota history. The damaged store will not be overwritten.",
                error: error,
                priority: 2
            )
            return
        }

        guard revision == historyReloadRevision else { return }
        var acceptedSummaries: [String: AccountHistorySummary] = [:]
        var acceptedRecent: [String: [UsageHistorySample]] = [:]
        for target in targets {
            guard accounts.contains(where: { $0.key == target.account.key }),
                  (try? lifecycleStore.isCurrent(
                    target.generation,
                    accountKey: target.account.key
                  )) == true
            else { continue }
            acceptedSummaries[target.account.key] = loaded.summaries[target.account.key]
            acceptedRecent[target.account.key] = loaded.recent[target.account.key]
        }
        historySummaries = acceptedSummaries
        recentHistorySamples = acceptedRecent
    }

    /// Reconciles data that another process can change. Account identity is
    /// deliberately excluded because only the app may link or remove accounts.
    /// The snapshot flock is held during the reads, so the guard keeps the
    /// process unsuspended until they finish (0xdead10cc).
    func reconcileSharedData() {
        guard !isDemo else { return }
        SuspensionGuard.withProtection(named: "SharedDataReconcile") {
            var loaded: [String: ProviderSnapshot] = [:]
            for account in accounts {
                do {
                    loaded[account.key] = try snapshotStore.current(accountKey: account.key)
                } catch {
                    reportStorageError(
                        "Vigil couldn't read the saved usage for \(account.displayName). It will keep the last in-memory value.",
                        error: error
                    )
                    loaded[account.key] = snapshots[account.key]
                }
            }
            snapshots = loaded
        }
        queueHistoryReload()
    }

    func history(for account: AccountRef) -> [UsageHistorySample] {
        recentHistorySamples[account.key] ?? []
    }

    func historySummary(
        for account: AccountRef,
        source: UsageHistorySource? = nil
    ) -> UsageHistorySummary? {
        guard let summary = historySummaries[account.key] else { return nil }
        if let source {
            return summary.summary(for: source)
        }
        return summary.all
    }

    func historyPage(
        for account: AccountRef,
        source: UsageHistorySource,
        cursor: UsageHistoryCursor? = nil,
        limit: Int = 100
    ) async throws -> UsageHistoryPage {
        let store = historyStore
        let accountKey = account.key
        return try await historyIO.perform {
            try store.page(
                accountKey: accountKey,
                source: source,
                limit: limit,
                cursor: cursor
            )
        }
    }

    func officialHistoryImportState(for account: AccountRef) -> OfficialHistoryImportState {
        officialHistoryImports[account.key] ?? .idle
    }

    var canExportDiagnostics: Bool {
        !accounts.isEmpty
            || !snapshots.isEmpty
            || historySummaries.values.contains { $0.all.sampleCount > 0 }
    }

    func makeDiagnosticExportData() throws -> Data {
        try DiagnosticExportBuilder().makeData(
            app: .current(),
            accounts: accounts,
            currentSnapshots: Array(snapshots.values),
            history: recentHistorySamples.values.flatMap { $0 },
            retainedHistoryCount: historySummaries.values.reduce(0) {
                $0 + $1.all.sampleCount
            }
        )
    }

    /// Builds the same allow-listed, credential-free support artifact as the
    /// Settings export, scoped to one linked account. The history payload is
    /// intentionally the bounded recent preview; `retainedHistoryCount` tells
    /// support tooling how many records remain available in the local archive.
    func makeDiagnosticExportData(for account: AccountRef) throws -> Data {
        try DiagnosticExportBuilder().makeData(
            app: .current(),
            accounts: [account],
            currentSnapshots: snapshots[account.key].map { [$0] } ?? [],
            history: recentHistorySamples[account.key] ?? [],
            retainedHistoryCount: historySummaries[account.key]?.all.sampleCount ?? 0
        )
    }

    /// Loads each account's ledger next-allowed time into UI state.
    func hydrateNextAllowed() async {
        let operationEpoch = identityMutationEpoch
        var next: [String: Date] = [:]
        for account in accounts {
            if let date = await scheduler.nextAllowedFetch(accountKey: account.key) {
                next[account.key] = date
            }
        }
        guard operationEpoch == identityMutationEpoch,
              !isResettingAllLocalData
        else { return }
        nextAllowed = next
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    func isRemovingAccount(_ accountKey: String) -> Bool {
        removingAccountKeys.contains(accountKey)
    }

    /// How this account was linked — shown as "Updated · OAuth / API / Local"
    /// under each provider row (token-monitor style).
    func connectionLabel(for account: AccountRef) -> String {
        if let credentials = try? vault.load(accountKey: account.key),
           let source = credentials.source?.lowercased() {
            switch source {
            case "mint": return "OAuth"
            case "file", "keychain": return "Local"
            case "manual": return "API"
            default: break
            }
        }
        // Only an explicit "mint" source proves Vigil owns a renewable pair.
        // Never infer OAuth from provider capability because manually pasted
        // Claude or Codex credentials do not belong to Vigil's refresh flow.
        if let spec = ProviderRegistry.spec(for: account.providerId), spec.oauth != nil {
            return "Linked"
        }
        return "API"
    }

    // MARK: - Linking

    enum LinkError: LocalizedError {
        case verifyFailed(SnapshotStatus)
        case unsupportedProvider(String)
        case invalidCredentials(String)
        case relinkTargetMissing
        case providerMismatch(expected: String, received: String)
        case providerAccountMismatch
        case wouldReplace([String])
        case verificationDeferred(Date?)
        case accountRemovalInProgress
        case historyRecoveryRequired(String)
        case persistence(String)

        var errorDescription: String? {
            switch self {
            case .verifyFailed(let status):
                switch status {
                case .authExpired:
                    return "The provider rejected these credentials. Check the key or sign in again, then retry."
                case .network:
                    return "Couldn't reach the provider to verify. Check your connection — or save anyway and verify later."
                case .schemaChanged:
                    return "The provider responded, but Vigil couldn't read its usage fields. Update Vigil, or save anyway and retry after an update."
                default:
                    return "Verification failed (\(status.rawValue))."
                }
            case .unsupportedProvider(let id):
                return "\"\(id)\" isn't supported by this version of Vigil. Update the app for the latest provider support."
            case .invalidCredentials(let reason):
                return "These credentials look invalid: \(reason). Check what you pasted and try again."
            case .relinkTargetMissing:
                return "This account is no longer linked. Close this screen and add it again."
            case .providerMismatch(let expected, let received):
                return "This re-link is for \(expected), but the new credential belongs to \(received)."
            case .providerAccountMismatch:
                return "The new sign-in belongs to a different provider account. Add it as a separate account instead."
            case .wouldReplace(let labels):
                return "This replaces the already-linked \(labels.joined(separator: ", "))."
            case .verificationDeferred:
                return "Vigil's polling safety gate deferred verification. Try again in a few minutes, or save now and verify on the next allowed refresh."
            case .accountRemovalInProgress:
                return "Vigil is already removing this account. Wait for removal to finish before adding or removing it again."
            case .historyRecoveryRequired(let message):
                return message
            case .persistence(let message):
                return message
            }
        }
    }

    static func accountKey(for credentials: Credentials) -> String {
        if let accountId = credentials.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountId.isEmpty {
            // Preserve the original account-id key format so existing Codex
            // links remain stable across this upgrade.
            return "\(credentials.providerId):\(accountId)"
        }

        // Providers such as Claude do not always expose an account id. The old
        // `provider:default` key collapsed every such login into one account.
        // A non-reversible credential fingerprint keeps separate accounts
        // distinct without putting any token material in filenames or logs.
        let identity = credentials.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
            ?? credentials.accessToken
        let digest = SHA256.hash(data: Data(identity.utf8))
        let fingerprint = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(credentials.providerId):credential:\(fingerprint)"
    }

    /// Adds one account (manual entry or link payload). Verify-then-store.
    func addAccount(credentials: Credentials, allowUnverified: Bool = false, allowReplace: Bool = false) async throws {
        try Task.checkCancellation()
        try ensureAccountIndexUsable()
        let operationEpoch = identityMutationEpoch
        guard ProviderRegistry.spec(for: credentials.providerId) != nil else {
            throw LinkError.unsupportedProvider(credentials.providerId)
        }
        try Self.validate(credentials)
        let ref = AccountRef(
            key: Self.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: credentials.label,
            plan: credentials.plan
        )
        guard !removingAccountKeys.contains(ref.key) else {
            throw LinkError.accountRemovalInProgress
        }
        guard !retiringAccountKeys.contains(ref.key) else {
            throw LinkError.persistence(
                "Vigil is finishing an interrupted removal for this account. Relaunch after the cleanup notice clears, then link it again."
            )
        }
        let existing = accounts.first { $0.key == ref.key }
        if let existing, !allowReplace {
            throw LinkError.wouldReplace([existing.label ?? existing.displayName])
        }
        if let existing {
            try await replaceCredentials(
                for: existing,
                with: credentials,
                allowUnverified: allowUnverified
            )
            return
        }

        let previousCredentials: Credentials?
        do {
            previousCredentials = try vault.load(accountKey: ref.key)
        } catch {
            reportStorageError(
                "Vigil couldn't read the existing Keychain state for \(ref.displayName). No account was changed.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't read the existing Keychain state. No account was changed."
            )
        }

        var credentialsToSave = credentials
        var verifiedSnapshot: ProviderSnapshot?
        if !allowUnverified {
            let result = await verify(account: ref, credentials: credentials)
            // URLSession cancellation is intentionally converted into a
            // non-persisted UsageService result so the shared poll floor can
            // still be charged. Restore structured cancellation at this
            // account-transaction boundary before interpreting that result or
            // writing any linked-account state.
            try Task.checkCancellation()
            try ensureIdentityOperationCurrent(operationEpoch)
            handle(result.persistenceIssue, account: ref)
            credentialsToSave = result.effectiveCredentials
            verifiedSnapshot = result.snapshot
            switch verifiedSnapshot?.status {
            case .some(let status) where status == .ok || status == .rateLimited:
                // A genuine provider response — even a 429 — proves the
                // credential reached the provider.
                break
            case .some(let status):
                throw LinkError.verifyFailed(status)
            case .none:
                if result.nextAllowed != nil {
                    throw LinkError.verificationDeferred(result.nextAllowed)
                }
                throw LinkError.verifyFailed(.network)
            }
        }

        try ensureIdentityOperationCurrent(operationEpoch)

        var updatedAccounts = accounts
        if let index = updatedAccounts.firstIndex(where: { $0.key == ref.key }) {
            updatedAccounts[index] = ref
        } else {
            updatedAccounts.append(ref)
        }

        // beginNewLifecycle is the first durable linked-account mutation. No
        // suspension follows until the Keychain and index transaction ends, so
        // a Cancel handled while verification was awaiting cannot cross this
        // boundary and create a partially linked account.
        try Task.checkCancellation()
        let commitGeneration: AccountLifecycleGeneration
        do {
            commitGeneration = try lifecycleStore.beginNewLifecycle(accountKey: ref.key)
        } catch {
            reportStorageError(
                "Vigil couldn't start a protected account transaction. No account was changed.",
                error: error,
                priority: 4
            )
            throw LinkError.persistence(
                "Vigil couldn't validate the account lifecycle. No account was changed."
            )
        }

        do {
            try lifecycleStore.withCurrentGeneration(
                commitGeneration,
                accountKey: ref.key
            ) {
                try vault.save(credentialsToSave, accountKey: ref.key)
            }
        } catch {
            try? lifecycleStore.tombstone(accountKey: ref.key)
            reportStorageError(
                "Vigil verified \(ref.displayName) but couldn't save its credentials. No account was added.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't save the credentials. No account was added."
            )
        }
        do {
            try AccountIndex.save(updatedAccounts, to: accountIndexURL)
        } catch {
            // The Keychain write happened first so the shared account index can
            // never advertise credentials that were not saved. Restore the
            // prior Keychain state if the index write then fails.
            do {
                if let previousCredentials {
                    try lifecycleStore.withCurrentGeneration(
                        commitGeneration,
                        accountKey: ref.key
                    ) {
                        try vault.save(previousCredentials, accountKey: ref.key)
                    }
                } else {
                    try lifecycleStore.withCurrentGeneration(
                        commitGeneration,
                        accountKey: ref.key
                    ) {
                        try vault.delete(accountKey: ref.key)
                    }
                    try lifecycleStore.tombstone(accountKey: ref.key)
                }
            } catch let rollbackError {
                reportStorageError(
                    "Vigil couldn't save the account index or restore the previous Keychain item. Remove and re-link this account.",
                    error: rollbackError
                )
                throw LinkError.persistence(
                    "Vigil couldn't safely finish linking. Remove and re-link this account."
                )
            }
            reportStorageError(
                "Vigil couldn't save the account list. The previous Keychain state was restored.",
                error: error
            )
            let cleared = await scheduler.clear(accountKey: ref.key)
            if !cleared, let detail = await scheduler.persistenceErrorDescription(accountKey: ref.key) {
                reportStorageError(
                    "Vigil restored the previous account state but couldn't clear the verification lease. \(detail)"
                )
            }
            throw LinkError.persistence("Vigil couldn't save the account list. No account was added.")
        }

        accounts = updatedAccounts
        if let verifiedSnapshot {
            snapshots[ref.key] = verifiedSnapshot
            do {
                try lifecycleStore.withCurrentGeneration(
                    commitGeneration,
                    accountKey: ref.key
                ) {
                    try snapshotStore.save(verifiedSnapshot, accountKey: ref.key)
                }
            } catch {
                reportStorageError(
                    "The account was linked, but Vigil couldn't save its verified usage snapshot.",
                    error: error
                )
            }
            if verifiedSnapshot.status == .ok {
                do {
                    try lifecycleStore.withCurrentGeneration(
                        commitGeneration,
                        accountKey: ref.key
                    ) {
                        try SuspensionGuard.withProtection(named: "HistoryAppend") {
                            try historyStore.append(snapshot: verifiedSnapshot)
                        }
                    }
                    queueHistoryReload()
                } catch {
                    reportStorageError(
                        "The account was linked, but Vigil couldn't archive its first successful reading.",
                        error: error,
                        priority: 2
                    )
                }
            }
        } else {
            do {
                snapshots[ref.key] = try snapshotStore.current(accountKey: ref.key)
            } catch {
                snapshots[ref.key] = nil
                reportStorageError(
                    "The account was linked, but Vigil couldn't read its saved usage snapshot.",
                    error: error
                )
            }
        }
        await notifications.requestAuthorizationIfNeeded()
        try ensureIdentityOperationCurrent(operationEpoch)
        reloadWidgets()
    }

    /// Repairs one existing Vigil account without deriving a new identity from
    /// replacement token material. History, widget intent selection, and the
    /// polling ledger remain attached to the target's stable local key.
    func replaceCredentials(
        for target: AccountRef,
        with credentials: Credentials,
        allowUnverified: Bool = false
    ) async throws {
        try Task.checkCancellation()
        try ensureAccountIndexUsable()
        let operationEpoch = identityMutationEpoch
        guard !removingAccountKeys.contains(target.key) else {
            throw LinkError.accountRemovalInProgress
        }
        guard accounts.contains(where: { $0.key == target.key }) else {
            throw LinkError.relinkTargetMissing
        }
        guard credentials.providerId == target.providerId else {
            throw LinkError.providerMismatch(
                expected: target.displayName,
                received: ProviderRegistry.spec(for: credentials.providerId)?.displayName
                    ?? credentials.providerId
            )
        }
        guard ProviderRegistry.spec(for: credentials.providerId) != nil else {
            throw LinkError.unsupportedProvider(credentials.providerId)
        }
        try Self.validate(credentials)
        let verificationGeneration: AccountLifecycleGeneration
        do {
            guard let captured = try lifecycleStore.captureActiveGeneration(
                accountKey: target.key
            ) else {
                throw LinkError.relinkTargetMissing
            }
            verificationGeneration = captured
        } catch let error as LinkError {
            throw error
        } catch {
            throw LinkError.persistence(
                "Vigil couldn't validate this account before re-linking. No account was changed."
            )
        }

        let previousCredentials: Credentials?
        do {
            previousCredentials = try vault.load(accountKey: target.key)
        } catch {
            reportStorageError(
                "Vigil couldn't read the existing Keychain state for \(target.displayName). No account was changed.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't read the existing Keychain state. No account was changed."
            )
        }
        if let previousID = previousCredentials?.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !previousID.isEmpty,
           let replacementID = credentials.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !replacementID.isEmpty,
           previousID != replacementID {
            throw LinkError.providerAccountMismatch
        }
        if let replacementID = credentials.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !replacementID.isEmpty,
           !target.key.hasPrefix("\(target.providerId):credential:"),
           Self.accountKey(for: credentials) != target.key {
            // The stable provider account ID is also encoded in pre-existing
            // local keys. Enforce it even if the old Keychain item is missing.
            throw LinkError.providerAccountMismatch
        }

        var replacement = target
        if let label = credentials.label { replacement.label = label }
        if let plan = credentials.plan { replacement.plan = plan }

        var credentialsToSave = credentials
        var verifiedSnapshot: ProviderSnapshot?
        if !allowUnverified {
            let result = await verify(
                account: replacement,
                credentials: credentials,
                generation: verificationGeneration
            )
            // See addAccount: UsageService finishes cancellation bookkeeping
            // before returning, then this method must rethrow cancellation
            // before it can rotate the account lifecycle or replace secrets.
            try Task.checkCancellation()
            try ensureIdentityOperationCurrent(operationEpoch)
            guard accounts.contains(where: { $0.key == target.key }),
                  (try? lifecycleStore.isCurrent(
                    verificationGeneration,
                    accountKey: target.key
                  )) == true
            else {
                throw LinkError.relinkTargetMissing
            }
            handle(result.persistenceIssue, account: replacement)
            credentialsToSave = result.effectiveCredentials
            verifiedSnapshot = result.snapshot
            switch verifiedSnapshot?.status {
            case .some(let status) where status == .ok || status == .rateLimited:
                break
            case .some(let status):
                throw LinkError.verifyFailed(status)
            case .none:
                if result.nextAllowed != nil {
                    throw LinkError.verificationDeferred(result.nextAllowed)
                }
                throw LinkError.verifyFailed(.network)
            }
        }

        // Capture only the exact process-local owner that existed before the
        // lifecycle rotation. A raw account-key cleanup after an await could
        // otherwise retire a fresh request acquired by the replacement
        // generation.
        let pollPolicy = ProviderRegistry.spec(for: target.providerId)?.poll
        let priorLease: FetchLease?
        if pollPolicy != nil {
            priorLease = await scheduler.activeLease(accountKey: target.key)
        } else {
            priorLease = nil
        }

        // activeLease crosses actors. Removal may have won while this method
        // was suspended, so revalidate immediately before the durable commit.
        // Nothing may suspend between this check and generation rotation.
        try Task.checkCancellation()
        try ensureIdentityOperationCurrent(operationEpoch)
        guard !removingAccountKeys.contains(target.key),
              let targetIndex = accounts.firstIndex(where: { $0.key == target.key }),
              (try? lifecycleStore.isCurrent(
                verificationGeneration,
                accountKey: target.key
              )) == true
        else {
            throw LinkError.relinkTargetMissing
        }
        var updatedAccounts = accounts
        updatedAccounts[targetIndex] = replacement
        // rotateActiveGeneration is the first durable re-link mutation and its
        // body owns the atomic lifecycle/Keychain/index transaction.
        try Task.checkCancellation()
        let commitGeneration: AccountLifecycleGeneration
        do {
            commitGeneration = try lifecycleStore.rotateActiveGeneration(
                accountKey: target.key
            ) { generation in
                try vault.save(credentialsToSave, accountKey: target.key)
                do {
                    try AccountIndex.save(updatedAccounts, to: accountIndexURL)
                } catch {
                    do {
                        if let previousCredentials {
                            try vault.save(previousCredentials, accountKey: target.key)
                        } else {
                            try vault.delete(accountKey: target.key)
                        }
                    } catch let rollbackError {
                        reportStorageError(
                            "Vigil couldn't save the account index or restore the previous Keychain item. Remove and re-link this account.",
                            error: rollbackError,
                            priority: 4
                        )
                        throw LinkError.persistence(
                            "Vigil couldn't safely finish re-linking. Remove and add this account again."
                        )
                    }
                    throw error
                }
                return generation
            }
        } catch let error as LinkError {
            throw error
        } catch {
            reportStorageError(
                "Vigil couldn't replace this account's credentials. The previous account state was preserved.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't safely replace the credentials. The previous account remains linked."
            )
        }

        // Publish the committed account row before the next suspension. If a
        // removal starts afterward, it sees and removes this exact committed
        // state rather than racing a late in-memory assignment.
        accounts = updatedAccounts

        // Rotation intentionally makes any older app/widget generation stale.
        // An app-process request may still own this scheduler actor's local
        // slot, and its now-stale guarded completion cannot release that slot.
        // Retire only the owner captured before rotation while preserving the
        // provider's polling floor. A new owner's token can never match it.
        if let policy = pollPolicy, let priorLease {
            let retired = await scheduler.retireInFlightForLifecycleRotation(
                priorLease,
                policy: policy
            )
            if !retired,
               let detail = await scheduler.persistenceErrorDescription(
                accountKey: target.key
               ) {
                reportStorageError(
                    "The account was re-linked, but Vigil couldn't finish reconciling its prior polling lease. The next check may wait for that lease to expire. \(detail)",
                    priority: 3
                )
            }
        }

        // The scheduler work above suspends. Removal may have completed during
        // it, so stale re-link work must never republish a snapshot or widget.
        guard !removingAccountKeys.contains(target.key),
              operationEpoch == identityMutationEpoch,
              !isResettingAllLocalData,
              accounts.contains(where: { $0.key == target.key }),
              (try? lifecycleStore.isCurrent(
                commitGeneration,
                accountKey: target.key
              )) == true
        else {
            throw LinkError.relinkTargetMissing
        }
        if let verifiedSnapshot {
            snapshots[target.key] = verifiedSnapshot
            do {
                try lifecycleStore.withCurrentGeneration(
                    commitGeneration,
                    accountKey: target.key
                ) {
                    try snapshotStore.save(verifiedSnapshot, accountKey: target.key)
                }
                if verifiedSnapshot.status == .ok {
                    try lifecycleStore.withCurrentGeneration(
                        commitGeneration,
                        accountKey: target.key
                    ) {
                        try SuspensionGuard.withProtection(named: "HistoryAppend") {
                            try historyStore.append(snapshot: verifiedSnapshot)
                        }
                    }
                    queueHistoryReload()
                }
            } catch {
                reportStorageError(
                    "The account was re-linked, but Vigil couldn't save its verified usage reading.",
                    error: error,
                    priority: 2
                )
            }
        }
        reloadWidgets()
    }

    /// Imports documented OpenAI API completion-usage buckets and organization
    /// cost buckets. This does not use or describe ChatGPT/Codex subscription
    /// activity.
    func importOfficialHistory(for account: AccountRef) async {
        guard account.providerId == "openai" else { return }
        guard accountIndexUsable, lifecycleUsable, !isResettingAllLocalData else { return }
        guard officialHistoryImports[account.key] != .importing else { return }
        let operationEpoch = identityMutationEpoch
        officialHistoryImports[account.key] = .importing

        do {
            guard let generation = try lifecycleStore.captureActiveGeneration(
                accountKey: account.key
            ) else {
                officialHistoryImports[account.key] = nil
                return
            }
            let loadedCredentials = try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try vault.load(accountKey: account.key)
            }
            guard let credentials = loadedCredentials else {
                officialHistoryImports[account.key] = .failed(
                    "The required OpenAI Admin API key is missing. \(ProviderPresentation.openAIAdminCredentialDisclosure) Re-link this account."
                )
                return
            }
            let endDate = Date()
            let result = try await OpenAIAdminHistoryClient().fetch(
                providerId: account.providerId,
                adminAPIKey: credentials.accessToken,
                startDate: endDate.addingTimeInterval(-365 * 86_400),
                endDate: endDate
            )

            // The account may have been removed while the provider requests
            // were in flight. Do not recreate its protected local history.
            guard operationEpoch == identityMutationEpoch,
                  !isResettingAllLocalData,
                  accounts.contains(where: { $0.key == account.key }),
                  try lifecycleStore.isCurrent(generation, accountKey: account.key)
            else {
                officialHistoryImports[account.key] = nil
                return
            }
            let samples = result.historySamples(
                accountKey: account.key,
                accountLabel: account.label,
                planLabel: snapshots[account.key]?.planLabel ?? account.plan
            )
            try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try SuspensionGuard.withProtection(named: "HistoryBackfill") {
                    try historyStore.importBackfill(samples)
                }
            }
            queueHistoryReload()
            officialHistoryImports[account.key] = .imported(
                sampleCount: samples.count,
                at: result.retrievedAt
            )
        } catch {
            guard operationEpoch == identityMutationEpoch,
                  !isResettingAllLocalData,
                  accounts.contains(where: { $0.key == account.key })
            else {
                officialHistoryImports[account.key] = nil
                return
            }
            officialHistoryImports[account.key] = .failed(
                Self.officialHistoryImportMessage(for: error)
            )
        }
    }

    /// Live verify: a real gated fetch. Returns nil when the ledger refused
    /// the fetch — meaning NOTHING was verified (a refusal proves nothing
    /// about the credential, unlike a provider 429).
    private func verify(
        account: AccountRef,
        credentials: Credentials,
        generation: AccountLifecycleGeneration? = nil
    ) async -> UsageService.Result {
        await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: snapshotStore,
            vault: nil,
            surface: "verify",
            session: usageSession,
            persistSnapshot: false,
            emitThresholdEvents: false,
            persistRotatedCredentials: false,
            allowCredentialRefresh: false,
            pendingEvents: pendingEvents,
            lifecycle: generation == nil ? nil : lifecycleStore,
            generation: generation
        )
    }

    func removeAccount(_ account: AccountRef) async throws {
        guard removingAccountKeys.insert(account.key).inserted else {
            throw LinkError.accountRemovalInProgress
        }
        let cleanupEpoch: UInt64
        do {
            cleanupEpoch = try beginDestructiveCleanup()
        } catch {
            removingAccountKeys.remove(account.key)
            throw error
        }
        defer {
            removingAccountKeys.remove(account.key)
            finishDestructiveCleanup()
        }

        try ensureAccountIndexUsable()
        // Invalidate first. Any app/widget write that began with the old
        // generation either finished before this lock was acquired (and will
        // be deleted below) or can never pass a guarded persistence point.
        do {
            try lifecycleStore.tombstone(accountKey: account.key)
        } catch {
            reportStorageError(
                "Vigil couldn't invalidate this account across the app and widgets. Nothing was removed.",
                error: error,
                priority: 4
            )
            throw LinkError.persistence(
                "Vigil couldn't safely begin removal. The account remains linked."
            )
        }
        // The lifecycle tombstone stops new app/widget persistence first.
        // Clear both queued and already-presented system notifications before
        // continuing with private local state removal.
        await notifications.removeNotifications(accountKey: account.key)
        guard destructiveCleanupIsCurrent(cleanupEpoch) else {
            throw LinkError.persistence(
                "Account removal was superseded by the full local-data reset."
            )
        }
        // Credentials are the privacy-critical state. Do not change the
        // account index or UI unless Keychain confirms deletion.
        do {
            try vault.delete(accountKey: account.key)
        } catch {
            // Removal did not happen. Reactivate with a fresh generation so
            // the already-invalidated in-flight work stays stale but future
            // user-initiated refreshes can continue.
            if (try? lifecycleStore.beginNewLifecycle(accountKey: account.key)) == nil {
                lifecycleUsable = false
            }
            reportStorageError(
                "Vigil couldn't delete this account's credentials from the Keychain. The account was not removed.",
                error: error
            )
            throw LinkError.persistence(
                "Vigil couldn't delete the Keychain credentials. The account remains linked."
            )
        }

        // Keep the account visible and indexed until every local cache is
        // deleted. If cleanup fails, the user can retry Remove rather than
        // being left with unreachable metadata.
        var cleanupError: Error?
        var historyCleanupError: Error?
        do {
            try snapshotStore.deleteRetiredAccount(accountKey: account.key)
        } catch {
            cleanupError = error
        }
        do {
            try pendingEvents.deleteRetiredAccount(accountKey: account.key)
        } catch {
            cleanupError = cleanupError ?? error
        }
        do {
            // Needed only when a failed startup migration left the retired
            // file in place. A removed account must not remain in that file.
            try legacyObservationStore.removeAll(accountKey: account.key)
        } catch {
            historyCleanupError = historyCleanupError ?? error
        }
        do {
            try SuspensionGuard.withProtection(named: "HistoryDelete") {
                try historyStore.delete(accountKey: account.key)
            }
            historySummaries[account.key] = nil
            recentHistorySamples[account.key] = nil
        } catch {
            historyCleanupError = historyCleanupError ?? error
        }
        if let historyCleanupError {
            reportStorageError(
                "Credentials were deleted, but Vigil couldn't read or update local usage history. The account remains visible until you choose how to recover.",
                error: historyCleanupError,
                priority: 3
            )
            throw LinkError.historyRecoveryRequired(
                "This account's credentials were deleted, but a local history file is damaged or unavailable. You can delete all local Vigil history for every account and finish removing this account."
            )
        }
        if let cleanupError {
            reportStorageError(
                "Credentials were deleted, but Vigil couldn't remove all cached usage metadata. The account remains visible so you can retry.",
                error: cleanupError
            )
            throw LinkError.persistence(
                "Credentials were deleted, but some cached usage metadata could not be removed. Try Remove again."
            )
        }
        do {
            try AccountIndex.deleteCorruptBackups(
                in: accountIndexURL.deletingLastPathComponent()
            )
            hasAccountRepairBackups = false
        } catch {
            reportStorageError(
                "Credentials and current usage were deleted, but Vigil couldn't remove an older damaged account-index backup. The account remains visible so you can retry.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Private data was deleted, but an older account-index backup could not be removed. Try Remove again."
            )
        }

        // Ledger deletion is part of the removal transaction, not detached
        // cleanup. Await it while the tombstone is still authoritative so a
        // successful return guarantees no old clear can erase a prompt
        // re-link's new generation state.
        let ledgerCleared = await scheduler.clear(accountKey: account.key)
        guard destructiveCleanupIsCurrent(cleanupEpoch) else {
            throw LinkError.persistence(
                "Account removal was superseded by the full local-data reset."
            )
        }
        guard ledgerCleared else {
            let detail = await scheduler.persistenceErrorDescription(accountKey: account.key)
                ?? "The polling ledger could not remove this account."
            reportStorageError(
                "Credentials and cached usage were deleted, but Vigil couldn't clear the polling ledger. The account remains visible so you can retry. \(detail)",
                priority: 3
            )
            throw LinkError.persistence(
                "Private data was deleted, but the polling ledger could not be cleared. Try Remove again."
            )
        }

        let updatedAccounts = accounts.filter { $0.key != account.key }
        do {
            try AccountIndex.save(updatedAccounts, to: accountIndexURL)
        } catch {
            // Keep the account visible so the incomplete cleanup is obvious
            // and can be retried. Credentials and cached usage are already
            // gone, so a retry is safe.
            reportStorageError(
                "Credentials and cached usage were deleted, but Vigil couldn't update its account list. Try Remove again.",
                error: error
            )
            throw LinkError.persistence(
                "Private data was deleted, but the account list could not be updated. Try Remove again."
            )
        }

        accounts = updatedAccounts
        snapshots[account.key] = nil
        nextAllowed[account.key] = nil
        officialHistoryImports[account.key] = nil
        // Final generation-scoped sweep. Old writers cannot pass the
        // tombstone, so this second delete is conclusive even if a write
        // finished immediately before invalidation.
        sweepRemovedLocalState(for: account.key)
        do {
            _ = try lifecycleStore.removeEntry(
                accountKey: account.key,
                ifStatus: .tombstoned
            )
        } catch {
            // The account and every user-facing/private store are already
            // gone. Keep this as a visible repair notice; startup reconciliation
            // will retry pruning the tombstone without resurrecting the account.
            reportStorageError(
                "The account was removed, but Vigil couldn't prune its retired lifecycle metadata. It will retry after relaunch.",
                error: error,
                priority: 2
            )
        }
        reloadWidgets()
    }

    func deleteAccountRepairBackups() throws {
        do {
            try AccountIndex.deleteCorruptBackups(
                in: accountIndexURL.deletingLastPathComponent()
            )
            hasAccountRepairBackups = false
        } catch {
            reportStorageError(
                "Vigil couldn't delete its damaged account-index repair backups.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't delete the repair backups. Check available storage and try again."
            )
        }
    }

    /// Last-resort, user-confirmed recovery for an identity registry Vigil
    /// cannot safely interpret. The sequence is crash-safe: first replace the
    /// unreadable lifecycle state with tombstones, then delete credentials and
    /// account data, then publish an empty index, and only then clear the
    /// tombstones. A failure at any intermediate step remains fail-closed and
    /// can be retried from Settings or completed by startup reconciliation.
    func resetAllLocalDataForRecovery() async throws {
        guard requiresFullLocalDataRecovery else {
            throw LinkError.persistence(
                "Vigil's identity stores are usable. Full recovery reset is not required."
            )
        }
        guard !isResettingAllLocalData else {
            throw LinkError.persistence("Vigil is already erasing its local data.")
        }
        isResettingAllLocalData = true
        defer { isResettingAllLocalData = false }
        identityMutationEpoch &+= 1
        historyReloadRevision &+= 1
        foregroundTimer?.cancel()
        foregroundTimer = nil
        // Account removal and interrupted-startup cleanup use account-wide
        // notification and ledger deletion. Let those already-started calls
        // return under the old epoch before reset can report success and allow
        // the user to link a new owner under the same key.
        await waitForDestructiveCleanup()
        // A drain that reached Notification Center before the reset flag was
        // raised may still be suspended there. Wait for its delivery and
        // stale-generation cleanup before erasing notification state.
        await waitForNotificationDeliveries()

        let credentialKeys: Set<String>
        do {
            credentialKeys = Set(try vault.allKeys())
        } catch {
            reportStorageError(
                "Vigil couldn't enumerate its Keychain credentials, so it did not begin the full reset.",
                error: error,
                priority: 4
            )
            throw LinkError.persistence(
                "Vigil couldn't enumerate every Keychain credential. No recovery reset was started."
            )
        }
        let recoveryKeys = credentialKeys.union(accounts.map(\.key))

        let lifecycleStores = fullRecoveryDirectories.map {
            AccountLifecycleStore(directory: $0)
        }
        do {
            for store in lifecycleStores {
                try store.forceRecoveryTombstones(accountKeys: recoveryKeys)
            }
        } catch {
            reportStorageError(
                "Vigil couldn't invalidate app and widget access before the full reset. No credential was deleted.",
                error: error,
                priority: 4
            )
            throw LinkError.persistence(
                "Vigil couldn't safely begin the reset. No Keychain credential was deleted."
            )
        }

        await notifications.removeAllVigilNotifications()

        var credentialDeletionError: Error?
        for accountKey in recoveryKeys.sorted() {
            do {
                try vault.delete(accountKey: accountKey)
            } catch {
                credentialDeletionError = credentialDeletionError ?? error
            }
        }
        do {
            let remainingKeys = try vault.allKeys()
            if !remainingKeys.isEmpty, credentialDeletionError == nil {
                credentialDeletionError = FullLocalRecoveryError.credentialsRemain(
                    remainingKeys.count
                )
            }
        } catch {
            credentialDeletionError = credentialDeletionError ?? error
        }
        if let credentialDeletionError {
            reportStorageError(
                "Vigil invalidated provider access but couldn't verify deletion of every Keychain credential. Recovery remains blocked and can be retried.",
                error: credentialDeletionError,
                priority: 4
            )
            throw LinkError.persistence(
                "Vigil couldn't verify that every Keychain credential was deleted. The reset remains fail-closed; try again."
            )
        }

        do {
            try await scheduler.resetAll()
            let currentDirectoryPath = accountIndexURL.deletingLastPathComponent()
                .standardizedFileURL.path
            let recoveryDirectories = fullRecoveryDirectories
            try await historyIO.perform {
                for directory in recoveryDirectories {
                    if directory.standardizedFileURL.path != currentDirectoryPath {
                        try FileLedgerStore(directory: directory).reset()
                    }
                    try UsageHistoryStore(directory: directory).deleteAll()
                    try LegacyUsageObservationStore(directory: directory).deleteAll()
                    try LocalDataRecoveryResetter.deleteAccountCachesAndIndex(in: directory)
                    try AccountIndex.save(
                        [],
                        to: directory.appendingPathComponent("account-index.json")
                    )
                }
            }
            for store in lifecycleStores {
                try store.finishFullRecoveryReset()
            }
        } catch {
            reportStorageError(
                "Vigil deleted its credentials but couldn't finish clearing every local cache. The reset remains blocked and can be retried.",
                error: error,
                priority: 4
            )
            throw LinkError.persistence(
                "Credentials were deleted, but Vigil couldn't finish clearing local data. Try the recovery reset again."
            )
        }

        // New drains have been blocked for the entire reset, and every older
        // delivery has returned. Sweep once more immediately before success so
        // no accepted request can survive the user's "erase everything" action.
        await notifications.removeAllVigilNotifications()
        LegacyNetworkStorageCleaner.removeAppScopedSharedSessionData()

        accounts = []
        snapshots = [:]
        nextAllowed = [:]
        historySummaries = [:]
        recentHistorySamples = [:]
        officialHistoryImports = [:]
        retiringAccountKeys = []
        removingAccountKeys = []
        hasAccountRepairBackups = false
        lifecycleUsable = true
        accountIndexUsable = true
        requiresFullLocalDataRecovery = false
        storageErrorMessage = nil
        storageErrorPriority = 0
        pendingStorageNotices = []
        reloadWidgets()
        if !Self.isRunningUnitTests {
            // The reset flag is cleared by the function's defer. Re-enter the
            // main actor afterward so the guarded timer cannot start while the
            // destructive operation is still observable as active.
            Task { [weak self] in
                await Task.yield()
                self?.startForegroundTimer()
            }
        }
    }

    private enum FullLocalRecoveryError: LocalizedError {
        case credentialsRemain(Int)

        var errorDescription: String? {
            switch self {
            case .credentialsRemain(let count):
                return "\(count) Keychain credential reference\(count == 1 ? "" : "s") remained after deletion."
            }
        }
    }

    /// Explicit recovery for a removal blocked by unreadable history. This is
    /// intentionally separate from `removeAccount`: the repair discards the
    /// normalized and retired history files for every account, so the UI must
    /// obtain a second, specific confirmation before calling it.
    func finishRemovalByDeletingAllHistory(_ account: AccountRef) async throws {
        let operationEpoch = identityMutationEpoch
        try ensureAccountIndexUsable()
        let historyStore = historyStore
        let legacyObservationStore = legacyObservationStore
        do {
            try await historyIO.perform {
                try historyStore.deleteAll()
                try legacyObservationStore.deleteAll()
            }
        } catch {
            reportStorageError(
                "Vigil couldn't delete the damaged local history files. The account remains visible.",
                error: error,
                priority: 3
            )
            throw LinkError.persistence(
                "Vigil couldn't delete all local history. Check available storage and try again."
            )
        }

        try ensureIdentityOperationCurrent(operationEpoch)
        historySummaries.removeAll()
        recentHistorySamples.removeAll()
        try await removeAccount(account)
    }

    /// Best-effort removal of on-disk state a late in-flight fetch recreated
    /// for an account the user already removed. Failures are logged rather than
    /// surfaced: the removal itself already succeeded and reported its own
    /// result, and this runs on a path the user is not waiting on.
    private func sweepRemovedLocalState(for accountKey: String) {
        do {
            try vault.delete(accountKey: accountKey)
        } catch {
            Self.log.error("late credential sweep failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
        do {
            try snapshotStore.deleteRetiredAccount(accountKey: accountKey)
        } catch {
            Self.log.error("late snapshot sweep failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
        do {
            try legacyObservationStore.removeAll(accountKey: accountKey)
        } catch {
            Self.log.error("late legacy-history sweep failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
        do {
            try SuspensionGuard.withProtection(named: "HistoryDelete") {
                try historyStore.delete(accountKey: accountKey)
            }
            historySummaries[accountKey] = nil
            recentHistorySamples[accountKey] = nil
        } catch {
            Self.log.error("late history sweep failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
        do {
            try pendingEvents.deleteRetiredAccount(accountKey: accountKey)
        } catch {
            Self.log.error("late event sweep failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
        snapshots[accountKey] = nil
        nextAllowed[accountKey] = nil
    }

    // MARK: - Refresh

    struct RefreshReport: Equatable, Sendable {
        var fetched: Int
        var deferred: Int
        var failed: Int
        /// Earliest time any deferred account may be checked again.
        var nextAllowedAt: Date?

        var didFetchAnything: Bool { fetched > 0 }

        var userMessage: String {
            if fetched > 0 && deferred == 0 && failed == 0 {
                return "Updated \(fetched) account\(fetched == 1 ? "" : "s") from providers."
            }
            if fetched > 0 {
                var parts = ["Updated \(fetched)"]
                if deferred > 0 { parts.append("\(deferred) waiting on poll floor") }
                if failed > 0 { parts.append("\(failed) failed") }
                return parts.joined(separator: " · ")
            }
            if deferred > 0, let nextAllowedAt, nextAllowedAt > Date() {
                return "Providers were checked recently. Next safe refresh \(nextAllowedAt.formatted(date: .omitted, time: .shortened)) — showing last known values until then."
            }
            if deferred > 0 {
                return "Providers were checked recently. Showing last known values until the next safe refresh."
            }
            if failed > 0 {
                return "Couldn't reach \(failed) provider\(failed == 1 ? "" : "s"). Last known values stay visible."
            }
            return "Nothing to refresh."
        }
    }

    /// Ledger-gated refresh of every account. Safe to call aggressively —
    /// the scheduler enforces the real polling budget. Returns an honest
    /// summary so the UI never pretends a gated tap "updated live."
    @discardableResult
    func refreshAll(surface: String) async -> RefreshReport {
        guard !isDemo else {
            return RefreshReport(fetched: 0, deferred: 0, failed: 0, nextAllowedAt: nil)
        }
        guard !isResettingAllLocalData,
              accountIndexUsable,
              lifecycleUsable,
              !requiresFullLocalDataRecovery
        else {
            return RefreshReport(
                fetched: 0,
                deferred: 0,
                failed: accounts.count,
                nextAllowedAt: nil
            )
        }
        var fetched = 0
        var deferred = 0
        var failed = 0
        await withTaskGroup(of: AccountRefreshOutcome.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account: account, surface: surface) }
            }
            for await outcome in group {
                switch outcome {
                case .fetched: fetched += 1
                case .deferred: deferred += 1
                case .failed: failed += 1
                }
            }
        }
        // New snapshots are in the App Group, but WidgetKit does not watch the
        // container — without this the widget keeps rendering the previous
        // numbers until its own 30-minute timeline policy fires, so the home
        // screen disagrees with the app and a successful background refresh
        // produces no visible change. Gated on a real fetch so the 60-second
        // foreground timer does not burn WidgetKit's reload budget on no-ops.
        if fetched > 0 {
            queueHistoryReload()
            reloadWidgets()
        }
        let soonest = nextAllowed.values.filter { $0 > Date() }.min()
        return RefreshReport(
            fetched: fetched,
            deferred: deferred,
            failed: failed,
            nextAllowedAt: soonest
        )
    }

    private enum AccountRefreshOutcome: Sendable {
        case fetched
        case deferred
        case failed
    }

    @discardableResult
    private func refresh(account: AccountRef, surface: String) async -> AccountRefreshOutcome {
        guard !isDemo else { return .deferred }
        let generation: AccountLifecycleGeneration
        do {
            guard let captured = try lifecycleStore.captureActiveGeneration(accountKey: account.key) else {
                return .failed
            }
            generation = captured
        } catch {
            reportStorageError(
                "Vigil couldn't validate the account lifecycle for \(account.displayName). Provider writes were stopped.",
                error: error,
                priority: 4
            )
            return .failed
        }
        let credentials: Credentials
        do {
            let loaded = try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try vault.load(accountKey: account.key)
            }
            guard let loaded else {
                reportStorageError(
                    "Vigil couldn't find credentials for \(account.displayName). Re-link the account."
                )
                return .failed
            }
            credentials = loaded
        } catch {
            reportStorageError(
                "Vigil couldn't read \(account.displayName) credentials from the Keychain.",
                error: error
            )
            return .failed
        }
        // The fetch persists snapshots, history rows, and pending events under
        // cross-process file locks. The guard keeps the process unsuspended —
        // including after a BGAppRefreshTask completes — until they are
        // released; a mid-lock suspension is a 0xdead10cc kill.
        let result = await SuspensionGuard.withProtection(named: "AccountRefresh") {
            await UsageService.refresh(
                account: account,
                credentials: credentials,
                scheduler: scheduler,
                snapshots: snapshotStore,
                vault: vault,
                surface: surface,
                session: usageSession,
                pendingEvents: pendingEvents,
                history: historyStore,
                lifecycle: lifecycleStore,
                generation: generation
            )
        }
        // Always read the poll clock, but publish nothing until after this last
        // suspension has been followed by a lifecycle and index revalidation.
        // Removal can complete during either UsageService or scheduler awaits.
        let refreshedNextAllowed = await scheduler.nextAllowedFetch(accountKey: account.key)
        let generationStillCurrent = (try? lifecycleStore.isCurrent(
            generation,
            accountKey: account.key
        )) == true
        guard generationStillCurrent,
              accounts.contains(where: { $0.key == account.key })
        else {
            if !accounts.contains(where: { $0.key == account.key }) {
                Self.log.info("refresh completed for an account removed mid-flight; discarding result")
                sweepRemovedLocalState(for: account.key)
            } else {
                Self.log.info("refresh completed for an older account generation; discarding result")
            }
            return .failed
        }
        handle(result.persistenceIssue, account: account)
        nextAllowed[account.key] = refreshedNextAllowed

        if let snapshot = result.snapshot {
            snapshots[account.key] = snapshot
            if snapshot.status == .ok {
                await drainPendingEvents(for: account, generation: generation)
                return .fetched
            }
            await drainPendingEvents(for: account, generation: generation)
            // rateLimited / network / authExpired still produced a classified
            // outcome — treat as fetched for the report (we learned something).
            if snapshot.status == .rateLimited {
                return .deferred
            }
            return .failed
        }

        if result.nextAllowed != nil {
            await drainPendingEvents(for: account, generation: generation)
            return .deferred
        }
        await drainPendingEvents(for: account, generation: generation)
        return result.persistenceIssue == nil ? .deferred : .failed
    }

    func drainPendingEvents(
        for account: AccountRef,
        generation suppliedGeneration: AccountLifecycleGeneration? = nil,
        now: Date = Date()
    ) async {
        guard !isResettingAllLocalData else { return }
        let generation: AccountLifecycleGeneration
        do {
            if let suppliedGeneration {
                generation = suppliedGeneration
            } else if let captured = try lifecycleStore.captureActiveGeneration(
                accountKey: account.key
            ) {
                generation = captured
            } else {
                return
            }
        } catch {
            reportStorageError(
                "Vigil couldn't validate pending notifications for \(account.displayName).",
                error: error,
                priority: 3
            )
            return
        }
        let events: [ThresholdEvent]
        do {
            events = try pendingEvents.load(accountKey: account.key)
        } catch {
            reportStorageError(
                "Vigil couldn't read pending notifications for \(account.displayName).",
                error: error
            )
            return
        }
        guard !events.isEmpty else { return }

        let currentSnapshot: ProviderSnapshot?
        do {
            // A widget may have persisted both a newer snapshot and its
            // crossing while this app process was suspended. Read shared truth
            // under the same lifecycle generation immediately before
            // partitioning so stale in-memory state cannot discard that event.
            currentSnapshot = try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try snapshotStore.current(accountKey: account.key)
            }
        } catch let error as AccountLifecycleError
            where error == .inactiveAccount || error == .staleGeneration {
            return
        } catch {
            reportStorageError(
                "Vigil couldn't read the latest usage before validating pending notifications for \(account.displayName). Nothing was delivered.",
                error: error,
                priority: 3
            )
            return
        }
        if let currentSnapshot,
           currentSnapshot.fetchedAt >= (snapshots[account.key]?.fetchedAt ?? .distantPast) {
            snapshots[account.key] = currentSnapshot
        }
        let actionable = events.filter {
            ThresholdEngine.disposition(
                of: $0,
                against: currentSnapshot,
                at: now
            ) == .actionable
        }
        let discarded = events.filter { !actionable.contains($0) }
        if !discarded.isEmpty {
            do {
                // Remove unverifiable or stale work before any external
                // notification scheduling. Segment-aware acknowledgement does
                // not consume a newer reset cycle appended by the widget.
                try lifecycleStore.withCurrentGeneration(
                    generation,
                    accountKey: account.key
                ) {
                    try pendingEvents.acknowledge(discarded, accountKey: account.key)
                }
            } catch let error as AccountLifecycleError
                where error == .inactiveAccount || error == .staleGeneration {
                return
            } catch {
                reportStorageError(
                    "Vigil couldn't clear outdated pending notifications for \(account.displayName). Nothing was delivered.",
                    error: error,
                    priority: 2
                )
                return
            }
        }
        guard !actionable.isEmpty else { return }

        // Validate immediately before scheduling, but never hold the shared
        // lifecycle flock across UNUserNotificationCenter work. That external
        // await can involve system services and must not block account removal
        // or widget persistence. The guarded acknowledgement below prevents a
        // removed account from recreating its durable queue afterward.
        do {
            guard try lifecycleStore.isCurrent(generation, accountKey: account.key) else {
                return
            }
        } catch {
            reportStorageError(
                "Vigil couldn't validate pending notifications for \(account.displayName).",
                error: error,
                priority: 3
            )
            return
        }
        guard beginNotificationDelivery() else { return }
        defer { finishNotificationDelivery() }
        let deliveryScope = generation.notificationScope
        let failed = await notifications.deliver(
            events: actionable,
            account: account,
            deliveryScope: deliveryScope
        )
        let delivered = actionable.filter { !failed.contains($0) }
        do {
            try lifecycleStore.withCurrentGeneration(
                generation,
                accountKey: account.key
            ) {
                try pendingEvents.acknowledge(delivered, accountKey: account.key)
            }
        } catch let error as AccountLifecycleError
            where error == .inactiveAccount || error == .staleGeneration {
            // Account removal may tombstone the lifecycle while the system
            // notification center is accepting the request. Its first cleanup
            // can therefore finish before this notification appears. Remove
            // only this old generation's accepted identifiers. An account-wide
            // sweep could delete a notification created after a prompt re-link.
            if !delivered.isEmpty {
                await notifications.removeNotifications(
                    identifiers: delivered.map {
                        NotificationManager.notificationIdentifier(
                            accountKey: account.key,
                            deliveryScope: deliveryScope,
                            event: $0
                        )
                    }
                )
            }
            return
        } catch {
            reportStorageError(
                "Vigil scheduled notifications for \(account.displayName) but couldn't acknowledge them in its durable queue. They may appear again.",
                error: error,
                priority: 2
            )
        }
        if !failed.isEmpty {
            reportStorageError(
                "Vigil couldn't schedule \(failed.count) notification\(failed.count == 1 ? "" : "s") for \(account.displayName). They remain queued for retry.",
                priority: 2
            )
        }
    }

    func drainAllPendingEvents() async {
        for account in accounts {
            await drainPendingEvents(for: account)
        }
    }

    // MARK: - Foreground timer (fetch triggers, docs/architecture.md)

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            guard !isResettingAllLocalData,
                  accountIndexUsable,
                  lifecycleUsable,
                  !requiresFullLocalDataRecovery
            else { return }
            reconcileSharedData()
            startForegroundTimer()
            Task { await drainAllPendingEvents() }
        default:
            foregroundTimer?.cancel()
            foregroundTimer = nil
        }
    }

    func startForegroundTimer() {
        guard foregroundTimer == nil,
              !isResettingAllLocalData,
              accountIndexUsable,
              lifecycleUsable,
              !requiresFullLocalDataRecovery
        else { return }
        foregroundTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll(surface: "timer")
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    func dismissStorageError() {
        if let next = pendingStorageNotices.enumerated().max(by: {
            $0.element.priority < $1.element.priority
        }) {
            storageErrorMessage = next.element.message
            storageErrorPriority = next.element.priority
            pendingStorageNotices.remove(at: next.offset)
        } else {
            storageErrorMessage = nil
            storageErrorPriority = 0
        }
    }

    private func handle(_ issue: UsageService.PersistenceIssue?, account: AccountRef) {
        guard let issue else { return }
        let context: String
        if let label = account.label, !label.isEmpty {
            context = "\(account.displayName) (\(label))"
        } else {
            context = account.displayName
        }
        switch issue {
        case .rotatedCredentials:
            reportStorageError(
                "Vigil received rotated credentials for \(context) but couldn't save them. Re-link this account before refreshing again.",
                priority: 3
            )
        case .snapshot:
            reportStorageError(
                "Vigil fetched current usage for \(context) but couldn't save it. The displayed update may not survive a restart.",
                priority: 2
            )
        case .snapshotRead:
            reportStorageError(
                "Vigil couldn't read the existing usage snapshot for \(context), so it stopped before overwriting it.",
                priority: 2
            )
        case .history:
            reportStorageError(
                "Vigil fetched current usage for \(context) but couldn't append it to protected history. Current values remain available.",
                priority: 2
            )
        case .pendingEvents:
            reportStorageError(
                "Vigil detected a threshold crossing for \(context) but couldn't save the pending notification.",
                priority: 2
            )
        case .fetchLedger(let detail):
            reportStorageError(
                "Vigil couldn't safely update the shared polling ledger for \(context), so polling was stopped or deferred. \(detail)",
                priority: 2
            )
        case .accountLifecycle(let detail):
            lifecycleUsable = false
            requiresFullLocalDataRecovery = true
            reportStorageError(
                "Vigil couldn't validate the shared account lifecycle for \(context), so provider writes were stopped. Settings can erase all local Vigil data and start over. \(detail)",
                priority: 4
            )
        }
    }

    private static func validate(_ credentials: Credentials) throws {
        guard !credentials.accessToken.isEmpty,
              credentials.accessToken.utf8.count <= 65_536,
              !containsControlCharacters(credentials.accessToken)
        else {
            throw LinkError.invalidCredentials("the access token is empty or too large")
        }
        if let refreshToken = credentials.refreshToken,
           refreshToken.utf8.count > 65_536 || containsControlCharacters(refreshToken) {
            throw LinkError.invalidCredentials("the refresh token is too large")
        }
        if let accountID = credentials.accountId,
           accountID.utf8.count > 128 || containsControlCharacters(accountID) {
            throw LinkError.invalidCredentials("the account ID is malformed")
        }
        // {account_id} may live in a header template (Codex) or in the URL
        // template (GitHub username, xAI team id). RequestBuilder returns nil
        // without it, so saving such credentials would only mint a dead
        // account — reject up front instead.
        if let spec = ProviderRegistry.spec(for: credentials.providerId),
           ProviderPresentation.needsAccountId(spec) {
            guard let accountID = credentials.accountId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !accountID.isEmpty
            else {
                throw LinkError.invalidCredentials("the provider requires an account ID")
            }
        }
        if let label = credentials.label,
           label.utf8.count > 256 || containsControlCharacters(label) {
            throw LinkError.invalidCredentials("the account label is malformed")
        }
        if let plan = credentials.plan,
           plan.utf8.count > 128 || containsControlCharacters(plan) {
            throw LinkError.invalidCredentials("the plan label is malformed")
        }
        if let source = credentials.source,
           source.utf8.count > 32 || containsControlCharacters(source) {
            throw LinkError.invalidCredentials("the credential source is malformed")
        }
        if let expiry = credentials.expiresAt {
            let seconds = expiry.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds <= 253_402_300_799 else {
                throw LinkError.invalidCredentials("the expiry date is out of range")
            }
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .controlCharacters) != nil
    }

    private static func officialHistoryImportMessage(for error: Error) -> String {
        if let error = error as? OpenAIAdminHistoryError {
            switch error {
            case .missingAdminAPIKey:
                return "A stored OpenAI Admin API key is required. \(ProviderPresentation.openAIAdminCredentialDisclosure)"
            case .administratorAuthenticationRequired:
                return "OpenAI rejected this credential. \(ProviderPresentation.openAIAdminCredentialDisclosure)"
            case .httpStatus(let code):
                return "OpenAI couldn't import completion usage and cost records (HTTP \(code)). Try again later."
            case .invalidPagination, .invalidResponse:
                return "OpenAI returned an unexpected completion-usage or cost response. Update Vigil before trusting an import."
            case .unsupportedProvider:
                return "This account does not offer an official records import."
            case .invalidDateRange, .futureEndDate, .dateRangeTooLarge:
                return "Vigil could not construct a safe OpenAI history range."
            }
        }
        if error is URLError {
            return "Vigil couldn't reach OpenAI to import completion usage and cost records. Try again when this iPhone is online."
        }
        return "Vigil couldn't save the imported provider records. Existing history was not changed."
    }

    private func reportStorageError(
        _ message: String,
        error: Error? = nil,
        priority: Int = 1
    ) {
        if storageErrorMessage == message
            || pendingStorageNotices.contains(where: { $0.message == message }) {
            return
        }
        if storageErrorMessage == nil {
            storageErrorMessage = message
            storageErrorPriority = priority
        } else if priority > storageErrorPriority {
            pendingStorageNotices.append(
                StorageNotice(message: storageErrorMessage!, priority: storageErrorPriority)
            )
            storageErrorMessage = message
            storageErrorPriority = priority
        } else {
            pendingStorageNotices.append(StorageNotice(message: message, priority: priority))
        }
        if let error {
            Self.log.error(
                "\(message, privacy: .private(mask: .hash)) \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        } else {
            Self.log.error("\(message, privacy: .private(mask: .hash))")
        }
    }

    private func ensureAccountIndexUsable() throws {
        guard accountIndexUsable, lifecycleUsable else {
            throw LinkError.persistence(
                "The account identity registry is damaged and could not be recovered. Vigil blocked this change to protect existing Keychain references."
            )
        }
    }

    private func ensureIdentityOperationCurrent(_ epoch: UInt64) throws {
        guard epoch == identityMutationEpoch, !isResettingAllLocalData else {
            throw LinkError.persistence(
                "This account operation was canceled because Vigil erased its local identity data. Start again from the empty setup screen."
            )
        }
        try ensureAccountIndexUsable()
    }

    private func beginDestructiveCleanup() throws -> UInt64 {
        guard !isResettingAllLocalData else {
            throw LinkError.persistence(
                "Vigil is erasing its local data. Wait for recovery to finish."
            )
        }
        destructiveCleanupCount += 1
        return identityMutationEpoch
    }

    private func finishDestructiveCleanup() {
        precondition(destructiveCleanupCount > 0)
        destructiveCleanupCount -= 1
        guard destructiveCleanupCount == 0 else { return }
        let waiters = destructiveCleanupWaiters
        destructiveCleanupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForDestructiveCleanup() async {
        guard destructiveCleanupCount > 0 else { return }
        await withCheckedContinuation { continuation in
            destructiveCleanupWaiters.append(continuation)
        }
    }

    private func destructiveCleanupIsCurrent(_ epoch: UInt64) -> Bool {
        epoch == identityMutationEpoch && !isResettingAllLocalData
    }

    private func beginNotificationDelivery() -> Bool {
        guard !isResettingAllLocalData else { return false }
        notificationDeliveryCount += 1
        return true
    }

    private func finishNotificationDelivery() {
        precondition(notificationDeliveryCount > 0)
        notificationDeliveryCount -= 1
        guard notificationDeliveryCount == 0 else { return }
        let waiters = notificationDeliveryWaiters
        notificationDeliveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForNotificationDeliveries() async {
        guard notificationDeliveryCount > 0 else { return }
        await withCheckedContinuation { continuation in
            notificationDeliveryWaiters.append(continuation)
        }
    }

    private func recoverAccountsFromKeychain() throws -> [AccountRef] {
        try vault.allKeys().sorted().map { key in
            guard let credentials = try vault.load(accountKey: key) else {
                throw AccountIndexRecoveryError.missingCredential
            }
            return AccountRef(
                key: key,
                providerId: credentials.providerId,
                label: credentials.label,
                plan: credentials.plan
            )
        }
    }

    private enum AccountIndexRecoveryError: LocalizedError {
        case missingCredential

        var errorDescription: String? {
            switch self {
            case .missingCredential:
                return "A Keychain item disappeared during account-index recovery."
            }
        }
    }
}
