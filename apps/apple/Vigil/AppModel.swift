import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import VigilKit
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Root observable state: linked accounts, their snapshots, and the shared
/// fetch pipeline. All fetches — foreground timer, pull-to-refresh, background
/// task, menu bar — go through UsageService and therefore the ledger.
@MainActor
@Observable
final class AppModel {
    private static let log = Logger(subsystem: "app.vigil", category: "model")
    static let maximumFutureLinkSkewSeconds = QRDecoder.maximumFutureSkewSeconds

    private(set) var accounts: [AccountRef] = []
    private(set) var snapshots: [String: ProviderSnapshot] = [:]
    /// Ledger-imposed earliest next fetch per account (for "next check at").
    private(set) var nextAllowed: [String: Date] = [:]
    /// A visible, dismissible storage failure. Persistence failures must never
    /// be reduced to a log line because that can make the UI claim data is
    /// durable when it is not.
    private(set) var storageErrorMessage: String?
    private(set) var accountIndexUsable = true
    /// True when launched with `VIGIL_DEMO=1` (screenshot tooling only). In demo
    /// mode the accounts are seeded in memory and never fetched, so the seeded
    /// snapshots aren't overwritten by auth failures (there are no credentials).
    private(set) var isDemo = false
    /// Spend/balance observations for Day/Week/Month/Year/Lifetime heroes.
    private(set) var observations: [UsageObservation] = []

    let vault: any CredentialsStore
    let scheduler: FetchScheduler
    let snapshotStore: SnapshotStore
    let pendingEvents: PendingEventStore
    let notifications: NotificationManager
    private let accountIndexURL: URL
    private let observationStore: UsageObservationStore
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

    /// Home period filter (Day / Week / Month / Year / Lifetime).
    var selectedPeriod: UsagePeriod {
        didSet { UserDefaults.standard.set(selectedPeriod.rawValue, forKey: "app.vigil.selectedPeriod") }
    }

    private var foregroundTimer: Task<Void, Never>?

    init(
        vault: (any CredentialsStore)? = nil,
        directory: URL = SharedContainer.directory
    ) {
        self.vault = vault ?? SharedKeychain.credentialsStore()
        self.scheduler = FetchScheduler(store: FileLedgerStore(directory: directory))
        self.snapshotStore = SnapshotStore(directory: directory)
        self.pendingEvents = PendingEventStore(directory: directory)
        self.notifications = NotificationManager()
        self.accountIndexURL = directory.appendingPathComponent("account-index.json")
        self.observationStore = UsageObservationStore(directory: directory)
        self.lockEnabled = UserDefaults.standard.bool(forKey: "app.vigil.lockEnabled")
        if let raw = UserDefaults.standard.string(forKey: "app.vigil.selectedPeriod"),
           let period = UsagePeriod(rawValue: raw) {
            self.selectedPeriod = period
        } else {
            self.selectedPeriod = .day
        }
        loadFromDisk()
        surfaceSharedStorageFallbackIfNeeded()
        seedDemoDataIfRequested()
    }

    /// Screenshot tooling: with `VIGIL_DEMO=1`, replace the (empty on a fresh
    /// install) in-memory state with representative sample data. Nothing is
    /// written to disk and no fetch runs, so this cannot leak into real usage.
    private func seedDemoDataIfRequested() {
        guard DemoData.requested(in: ProcessInfo.processInfo.environment) else { return }
        isDemo = true
        let demo = DemoData.seed()
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
        do {
            accounts = try AccountIndex.load(from: accountIndexURL)
            accountIndexUsable = true
        } catch {
            do {
                let recovered = try recoverAccountsFromKeychain()
                _ = try AccountIndex.preserveCorruptFile(at: accountIndexURL)
                try AccountIndex.save(recovered, to: accountIndexURL)
                accounts = recovered
                accountIndexUsable = true
                let message = recovered.isEmpty
                    ? "Vigil preserved its damaged account index and rebuilt an empty account list because no Keychain credentials remained."
                    : "Vigil repaired its damaged account index from Keychain. Review the recovered accounts before continuing."
                reportStorageError(
                    message,
                    error: error,
                    priority: 4
                )
            } catch let recoveryError {
                accounts = []
                accountIndexUsable = false
                reportStorageError(
                    "Vigil couldn't read or safely recover its account index. Linking and removal are blocked so existing Keychain references are not overwritten.",
                    error: recoveryError,
                    priority: 4
                )
            }
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
        do {
            observations = try observationStore.load()
        } catch {
            observations = []
            reportStorageError(
                "Vigil couldn't read its usage history. Period spend totals may be incomplete until the next successful refresh.",
                error: error
            )
        }
        // Hydrate poll clocks so Home can tell the truth before the first tap.
        Task { await hydrateNextAllowed() }
    }

    /// Loads each account's ledger next-allowed time into UI state.
    func hydrateNextAllowed() async {
        var next: [String: Date] = [:]
        for account in accounts {
            if let date = await scheduler.nextAllowedFetch(accountKey: account.key) {
                next[account.key] = date
            }
        }
        nextAllowed = next
    }

    var hasAccounts: Bool { !accounts.isEmpty }

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
        if let spec = ProviderRegistry.spec(for: account.providerId), spec.oauth != nil {
            return "OAuth"
        }
        return "API"
    }

    // MARK: - Linking

    enum LinkError: LocalizedError {
        case verifyFailed(SnapshotStatus)
        case noAccounts
        case unsupportedProvider(String)
        case invalidCredentials(String)
        case wouldReplace([String])
        case verificationDeferred(Date?)
        case futureDated
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
            case .noAccounts: return "That link code contained no accounts."
            case .unsupportedProvider(let id):
                return "\"\(id)\" isn't supported by this version of Vigil. Update the app for the latest provider support."
            case .invalidCredentials(let reason):
                return "These credentials look invalid: \(reason). Check what you pasted and try again."
            case .wouldReplace(let labels):
                return "This replaces the already-linked \(labels.joined(separator: ", "))."
            case .verificationDeferred:
                return "Vigil's polling safety gate deferred verification. Try again in a few minutes, or save now and verify on the next allowed refresh."
            case .futureDated:
                return "This link code is dated in the future. Check both devices' clocks, then create a fresh code."
            case .persistence(let message):
                return message
            }
        }
    }

    /// Adds every account in a decoded vigil1 payload: live verify first,
    /// persist to Keychain only on success (docs/qr-protocol.md receiver
    /// algorithm). Throws .verifyFailed(.network) so the UI can offer
    /// "save anyway", and .wouldReplace so the UI confirms overwrites.
    func addAccounts(
        from payload: LinkPayload,
        allowUnverified: Bool = false,
        allowReplace: Bool = false,
        now: Date = Date()
    ) async throws {
        try ensureAccountIndexUsable()
        guard !payload.accounts.isEmpty else { throw LinkError.noAccounts }
        guard payload.iat <= Int(now.timeIntervalSince1970) + Self.maximumFutureLinkSkewSeconds else {
            throw LinkError.futureDated
        }

        let incoming = payload.accounts.map { linked in
            Credentials(
                providerId: linked.p,
                accessToken: linked.c.at,
                refreshToken: linked.c.rt,
                expiresAt: linked.c.exp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                accountId: linked.c.acct,
                label: linked.label,
                plan: linked.meta?.plan,
                source: linked.c.src
            )
        }
        for credentials in incoming where ProviderRegistry.spec(for: credentials.providerId) == nil {
            throw LinkError.unsupportedProvider(credentials.providerId)
        }
        for credentials in incoming {
            try Self.validate(credentials)
        }
        let incomingKeys = incoming.map(Self.accountKey(for:))
        guard Set(incomingKeys).count == incomingKeys.count else {
            throw LinkError.invalidCredentials("duplicate account entries")
        }
        // Conflicts checked up front so a multi-account payload never stores
        // half its accounts before asking about replacement.
        if !allowReplace {
            let conflicts = incoming.compactMap { creds -> String? in
                let key = Self.accountKey(for: creds)
                guard let existing = accounts.first(where: { $0.key == key }) else { return nil }
                return existing.label ?? existing.displayName
            }
            guard conflicts.isEmpty else { throw LinkError.wouldReplace(conflicts) }
        }
        for credentials in incoming {
            try await addAccount(credentials: credentials, allowUnverified: allowUnverified, allowReplace: true)
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
        try ensureAccountIndexUsable()
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
        let existing = accounts.first { $0.key == ref.key }
        if let existing, !allowReplace {
            throw LinkError.wouldReplace([existing.label ?? existing.displayName])
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
            handle(result.persistenceIssue, account: ref)
            credentialsToSave = result.effectiveCredentials
            verifiedSnapshot = result.snapshot
            switch verifiedSnapshot?.status {
            case .some(let status) where status == .ok || status == .rateLimited:
                // A genuine provider response — even a 429 — proves the
                // credential reached the provider (same rule as the CLI).
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

        var updatedAccounts = accounts
        if let index = updatedAccounts.firstIndex(where: { $0.key == ref.key }) {
            updatedAccounts[index] = ref
        } else {
            updatedAccounts.append(ref)
        }

        do {
            try vault.save(credentialsToSave, accountKey: ref.key)
        } catch {
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
                    try vault.save(previousCredentials, accountKey: ref.key)
                } else {
                    try vault.delete(accountKey: ref.key)
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
            if !cleared, let detail = await scheduler.persistenceErrorDescription() {
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
                try snapshotStore.save(verifiedSnapshot, accountKey: ref.key)
            } catch {
                reportStorageError(
                    "The account was linked, but Vigil couldn't save its verified usage snapshot.",
                    error: error
                )
            }
            if verifiedSnapshot.status == .ok {
                recordObservation(snapshot: verifiedSnapshot, account: ref)
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
        reloadWidgets()
    }

    /// Records spend/balance samples for period heroes. Failures are soft —
    /// missing history is better than blocking a successful refresh.
    private func recordObservation(snapshot: ProviderSnapshot, account: AccountRef) {
        guard let observation = UsageObservation.from(snapshot: snapshot, account: account) else {
            return
        }
        do {
            try observationStore.append(observation)
            observations = try observationStore.load()
        } catch {
            Self.log.error(
                "observation append failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Live verify: a real gated fetch. Returns nil when the ledger refused
    /// the fetch — meaning NOTHING was verified (a refusal proves nothing
    /// about the credential, unlike a provider 429).
    private func verify(
        account: AccountRef,
        credentials: Credentials
    ) async -> UsageService.Result {
        await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: snapshotStore,
            vault: nil,
            surface: "verify",
            persistSnapshot: false,
            emitThresholdEvents: false,
            persistRotatedCredentials: false,
            allowCredentialRefresh: false,
            pendingEvents: pendingEvents
        )
    }

    func removeAccount(_ account: AccountRef) throws {
        try ensureAccountIndexUsable()
        // Credentials are the privacy-critical state. Do not change the
        // account index or UI unless Keychain confirms deletion.
        do {
            try vault.delete(accountKey: account.key)
        } catch {
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
        do {
            try snapshotStore.delete(accountKey: account.key)
        } catch {
            cleanupError = error
        }
        do {
            try pendingEvents.delete(accountKey: account.key)
        } catch {
            cleanupError = cleanupError ?? error
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
        reloadWidgets()

        // Forget the poll clock so a re-link performs a genuine live verify
        // (checklist M4 step 11: re-add prompts fresh).
        Task { [weak self] in
            guard let self else { return }
            let cleared = await scheduler.clear(accountKey: account.key)
            if !cleared, let detail = await scheduler.persistenceErrorDescription() {
                reportStorageError(
                    "The account was removed, but Vigil couldn't clear its polling ledger. \(detail)"
                )
            }
        }
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
        let credentials: Credentials
        do {
            guard let loaded = try vault.load(accountKey: account.key) else {
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
        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: snapshotStore,
            vault: vault,
            surface: surface,
            pendingEvents: pendingEvents
        )
        handle(result.persistenceIssue, account: account)

        // Always sync the poll clock into UI — even when the ledger refused.
        nextAllowed[account.key] = await scheduler.nextAllowedFetch(accountKey: account.key)

        if let snapshot = result.snapshot {
            snapshots[account.key] = snapshot
            if snapshot.status == .ok {
                recordObservation(snapshot: snapshot, account: account)
                await drainPendingEvents(for: account)
                return .fetched
            }
            await drainPendingEvents(for: account)
            // rateLimited / network / authExpired still produced a classified
            // outcome — treat as fetched for the report (we learned something).
            if snapshot.status == .rateLimited {
                return .deferred
            }
            return .failed
        }

        if result.nextAllowed != nil {
            await drainPendingEvents(for: account)
            return .deferred
        }
        await drainPendingEvents(for: account)
        return result.persistenceIssue == nil ? .deferred : .failed
    }

    func drainPendingEvents(for account: AccountRef) async {
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
        let failed = await notifications.deliver(events: events, account: account)
        let delivered = events.filter { !failed.contains($0) }
        do {
            try pendingEvents.acknowledge(delivered, accountKey: account.key)
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
            startForegroundTimer()
            Task { await drainAllPendingEvents() }
        default:
            #if os(iOS)
            foregroundTimer?.cancel()
            foregroundTimer = nil
            #endif
            // macOS: keep ticking — the menu bar is the always-fresh surface.
        }
    }

    func startForegroundTimer() {
        guard foregroundTimer == nil else { return }
        foregroundTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll(surface: "timer")
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Menu bar (M7)

    /// "C 42% left · X 71% left" — the tightest remaining percentage for
    /// each visible account, with direction stated rather than implied.
    /// Degraded or stale accounts carry a warning mark: the most-glanced
    /// surface must not silently show old numbers as fresh.
    var menuBarTitle: String {
        let visibleAccounts = Array(accounts.prefix(2))
        var parts = visibleAccounts.map { account -> String in
            let accountMark = menuBarAccountMark(for: account)
            guard let snapshot = snapshots[account.key] else { return "\(accountMark) –" }
            let degraded = SnapshotFreshness.isDegraded(
                status: snapshot.status,
                fetchedAt: snapshot.fetchedAt
            )
            let warning = degraded ? " ⚠︎" : ""
            if let tightest = snapshot.windows.min(by: {
                UsagePresentation.remainingPercent(for: $0)
                    < UsagePresentation.remainingPercent(for: $1)
            }) {
                let remaining = UsagePresentation.remainingPercent(for: tightest)
                return "\(accountMark) \(Int(remaining.rounded()))% left\(warning)"
            }
            if let metric = snapshot.metrics.first(where: { !$0.secondary })
                ?? snapshot.metrics.first {
                return "\(accountMark) \(Self.compactMetric(metric))\(warning)"
            }
            return "\(accountMark) –\(warning)"
        }
        if accounts.count > visibleAccounts.count {
            parts.append("+\(accounts.count - visibleAccounts.count)")
        }
        return parts.isEmpty ? "Vigil" : parts.joined(separator: " · ")
    }

    private func menuBarAccountMark(for account: AccountRef) -> String {
        let letter = account.providerId == "claude"
            ? "C"
            : account.providerId == "codex"
                ? "X"
                : String(account.displayName.prefix(1))
        let matchingAccounts = accounts.filter { $0.providerId == account.providerId }
        guard matchingAccounts.count > 1 else { return letter }

        if let label = account.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return "\(letter):\(String(label.prefix(10)))"
        }
        let index = (matchingAccounts.firstIndex(of: account) ?? 0) + 1
        return "\(letter)\(index)"
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
        }
    }

    private static func compactMetric(_ metric: UsageMetric) -> String {
        let value = metric.value.formatted(
            .number.precision(.fractionLength(0...2))
        )
        return metric.unit.map { "\(value) \($0)" } ?? value
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
        guard accountIndexUsable else {
            throw LinkError.persistence(
                "The account index is damaged and could not be recovered. Vigil blocked this change to protect existing Keychain references."
            )
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
