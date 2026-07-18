import Foundation
import Observation
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
    private(set) var accounts: [AccountRef] = []
    private(set) var snapshots: [String: ProviderSnapshot] = [:]
    /// Ledger-imposed earliest next fetch per account (for "next check at").
    private(set) var nextAllowed: [String: Date] = [:]

    let vault: any CredentialsStore
    let scheduler: FetchScheduler
    let snapshotStore: SnapshotStore
    let pendingEvents: PendingEventStore
    let notifications: NotificationManager

    /// Stored (not computed) so @Observable tracking sees changes; persisted
    /// to UserDefaults as a side effect.
    var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "app.vigil.lockEnabled") }
    }

    private var foregroundTimer: Task<Void, Never>?

    init(
        vault: (any CredentialsStore)? = nil,
        directory: URL = SharedContainer.directory
    ) {
        self.vault = vault ?? KeychainCredentialsStore()
        self.scheduler = FetchScheduler(store: FileLedgerStore(directory: directory))
        self.snapshotStore = SnapshotStore(directory: directory)
        self.pendingEvents = PendingEventStore(directory: directory)
        self.notifications = NotificationManager()
        self.lockEnabled = UserDefaults.standard.bool(forKey: "app.vigil.lockEnabled")
        loadFromDisk()
    }

    /// Instant render on relaunch: accounts + last snapshots, zero network.
    func loadFromDisk() {
        accounts = AccountIndex.load()
        var loaded: [String: ProviderSnapshot] = [:]
        for account in accounts {
            loaded[account.key] = snapshotStore.current(accountKey: account.key)
        }
        snapshots = loaded
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    // MARK: - Linking

    enum LinkError: LocalizedError {
        case verifyFailed(SnapshotStatus)
        case noAccounts
        case unsupportedProvider(String)
        case wouldReplace([String])

        var errorDescription: String? {
            switch self {
            case .verifyFailed(let status):
                switch status {
                case .authExpired: return "The provider rejected these credentials. Re-run `npx vigil-link` and try again."
                case .network: return "Couldn't reach the provider to verify. Check your connection — or save anyway and verify later."
                default: return "Verification failed (\(status.rawValue))."
                }
            case .noAccounts: return "That link code contained no accounts."
            case .unsupportedProvider(let id):
                return "\"\(id)\" isn't supported by this version of Vigil. Update Vigil and re-run `npx vigil-link`."
            case .wouldReplace(let labels):
                return "This replaces the already-linked \(labels.joined(separator: ", "))."
            }
        }
    }

    /// Adds every account in a decoded vigil1 payload: live verify first,
    /// persist to Keychain only on success (docs/qr-protocol.md receiver
    /// algorithm). Throws .verifyFailed(.network) so the UI can offer
    /// "save anyway", and .wouldReplace so the UI confirms overwrites.
    func addAccounts(from payload: LinkPayload, allowUnverified: Bool = false, allowReplace: Bool = false) async throws {
        guard !payload.accounts.isEmpty else { throw LinkError.noAccounts }

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
        "\(credentials.providerId):\(credentials.accountId ?? "default")"
    }

    /// Adds one account (manual entry or link payload). Verify-then-store.
    func addAccount(credentials: Credentials, allowUnverified: Bool = false, allowReplace: Bool = false) async throws {
        guard ProviderRegistry.spec(for: credentials.providerId) != nil else {
            throw LinkError.unsupportedProvider(credentials.providerId)
        }
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

        if !allowUnverified {
            switch await verify(account: ref, credentials: credentials) {
            case .some(let status) where status == .ok || status == .rateLimited:
                // A genuine provider response — even a 429 — proves the
                // credential reached the provider (same rule as the CLI).
                break
            case .some(let status):
                throw LinkError.verifyFailed(status)
            case .none where existing != nil:
                // Ledger refused the verify fetch (re-link inside the poll
                // window). Acceptable only for re-linking an account that was
                // verified before.
                break
            case .none:
                throw LinkError.verifyFailed(.network)
            }
        }

        try vault.save(credentials, accountKey: ref.key)
        if let index = accounts.firstIndex(where: { $0.key == ref.key }) {
            accounts[index] = ref
        } else {
            accounts.append(ref)
        }
        AccountIndex.save(accounts)
        snapshots[ref.key] = snapshotStore.current(accountKey: ref.key)
        await notifications.requestAuthorizationIfNeeded()
        reloadWidgets()
    }

    /// Live verify: a real gated fetch. Returns nil when the ledger refused
    /// the fetch — meaning NOTHING was verified (a refusal proves nothing
    /// about the credential, unlike a provider 429).
    private func verify(account: AccountRef, credentials: Credentials) async -> SnapshotStatus? {
        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: snapshotStore,
            vault: vault,
            surface: "verify"
        )
        if let snapshot = result.snapshot {
            snapshots[account.key] = snapshot
            return snapshot.status
        }
        return nil
    }

    func removeAccount(_ account: AccountRef) {
        try? vault.delete(accountKey: account.key)
        snapshotStore.delete(accountKey: account.key)
        pendingEvents.delete(accountKey: account.key)
        accounts.removeAll { $0.key == account.key }
        snapshots[account.key] = nil
        nextAllowed[account.key] = nil
        AccountIndex.save(accounts)
        reloadWidgets()
        // Forget the poll clock so a re-link performs a genuine live verify
        // (checklist M4 step 11: re-add prompts fresh).
        Task { await scheduler.clear(accountKey: account.key) }
    }

    // MARK: - Refresh

    /// Ledger-gated refresh of every account. Safe to call aggressively —
    /// the scheduler enforces the real polling budget.
    func refreshAll(surface: String) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account: account, surface: surface) }
            }
        }
    }

    func refresh(account: AccountRef, surface: String) async {
        guard let credentials = try? vault.load(accountKey: account.key) else { return }
        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: snapshotStore,
            vault: vault,
            surface: surface
        )
        if let snapshot = result.snapshot {
            snapshots[account.key] = snapshot
            nextAllowed[account.key] = await scheduler.nextAllowedFetch(accountKey: account.key)
        } else if let next = result.nextAllowed {
            nextAllowed[account.key] = next
        }
        // Crossings are computed inside UsageService (every surface) and
        // parked in the shared container; the app process delivers them —
        // including ones a widget refresh detected while the app was closed.
        await drainPendingEvents(for: account)
    }

    func drainPendingEvents(for account: AccountRef) async {
        let events = pendingEvents.drain(accountKey: account.key)
        guard !events.isEmpty else { return }
        await notifications.deliver(events: events, account: account)
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

    /// "C 42% · X 71%" — session-window utilization per linked provider.
    /// Degraded or stale accounts carry a warning mark: the most-glanced
    /// surface must not silently show old numbers as fresh.
    var menuBarTitle: String {
        let parts = accounts.map { account -> String in
            let letter = account.providerId == "claude" ? "C" : account.providerId == "codex" ? "X" : String(account.displayName.prefix(1))
            guard let snapshot = snapshots[account.key] else { return "\(letter) –" }
            let degraded = snapshot.status != .ok
                || Date().timeIntervalSince(snapshot.fetchedAt) > 1800
            let mark = degraded ? "⚠︎" : ""
            guard let session = snapshot.windows.first(where: { $0.id == "session" }) else {
                return "\(letter) –\(mark)"
            }
            return "\(letter) \(Int(session.utilization.rounded()))%\(mark)"
        }
        return parts.isEmpty ? "Vigil" : parts.joined(separator: " · ")
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
