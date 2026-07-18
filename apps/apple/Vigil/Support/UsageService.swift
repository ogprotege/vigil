import Foundation
import OSLog
import VigilKit

/// One ledger-gated fetch: acquire -> request -> classify -> snapshot ->
/// recordResult. Shared by the app, the widget timeline provider, and
/// background refresh so every surface obeys the same budget.
enum UsageService {
    static let log = Logger(subsystem: "app.vigil", category: "fetch")

    struct Result: Sendable {
        let snapshot: ProviderSnapshot?
        /// Non-nil when the ledger refused the fetch.
        let nextAllowed: Date?
    }

    /// Performs a single gated fetch for one account and persists the outcome.
    /// Returns the saved snapshot, or the ledger's next-allowed time when the
    /// fetch was refused. Never throws — failures degrade into snapshot
    /// statuses per the shared error taxonomy. A 401 on Vigil-minted
    /// credentials triggers one refresh + retry inside the same ledger slot;
    /// the rotated pair is persisted to `vault`.
    static func refresh(
        account: AccountRef,
        credentials: Credentials,
        scheduler: FetchScheduler,
        snapshots: SnapshotStore,
        vault: (any CredentialsStore)? = nil,
        surface: String
    ) async -> Result {
        guard let spec = ProviderRegistry.spec(for: account.providerId) else {
            return Result(snapshot: nil, nextAllowed: nil)
        }

        guard await scheduler.acquire(accountKey: account.key, policy: spec.poll) else {
            let next = await scheduler.nextAllowedFetch(accountKey: account.key)
            log.info("[\(surface)] \(account.key, privacy: .public): ledger refused fetch, next allowed \(next?.description ?? "unknown", privacy: .public)")
            return Result(snapshot: nil, nextAllowed: next)
        }

        log.info("[\(surface)] \(account.key, privacy: .public): fetching")
        let previous = snapshots.current(accountKey: account.key)
        var status: SnapshotStatus
        var planLabel: String?
        var windows: [UsageWindow]

        do {
            let request = RequestBuilder.usageRequest(spec: spec, credentials: credentials)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = UsageClient.classify(data: data, statusCode: code, spec: spec)
            status = outcome.status
            planLabel = outcome.planLabel
            windows = outcome.windows
        } catch {
            // Cancellation (scene ended, BG task expired) is not a provider
            // failure: release the in-flight lock without charging the ledger
            // clock or painting the account "offline".
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                await scheduler.release(accountKey: account.key)
                log.info("[\(surface)] \(account.key, privacy: .public): cancelled, released")
                return Result(snapshot: nil, nextAllowed: nil)
            }
            status = .network
            planLabel = nil
            windows = []
        }

        // Error taxonomy: 401 -> refresh once -> retry -> else authExpired.
        // Only for credentials Vigil minted (TokenRefresher refuses others).
        // Runs inside the held acquire: one ledger slot covers the 401, the
        // token rotation, and the retry.
        if status == .authExpired,
           let outcome = await refreshAndRetry(spec: spec, credentials: credentials, account: account, vault: vault, surface: surface) {
            status = outcome.status
            planLabel = outcome.planLabel
            windows = outcome.windows
        }

        // Honest degradation: a failed fetch keeps showing the last good data,
        // tinted stale — fetchedAt stays at the moment the data was true. An
        // account that has NEVER succeeded carries .distantPast, not a
        // fabricated freshness.
        let snapshot: ProviderSnapshot
        if status == .ok {
            snapshot = ProviderSnapshot(
                providerId: account.providerId,
                accountKey: account.key,
                accountLabel: account.label,
                planLabel: planLabel ?? account.plan,
                fetchedAt: Date(),
                status: .ok,
                windows: windows
            )
        } else {
            snapshot = ProviderSnapshot(
                providerId: account.providerId,
                accountKey: account.key,
                accountLabel: account.label,
                planLabel: previous?.planLabel ?? account.plan,
                fetchedAt: previous?.fetchedAt ?? .distantPast,
                status: status,
                windows: previous?.windows ?? []
            )
        }

        try? snapshots.save(snapshot, accountKey: account.key)
        // Crossings are computed here — the single choke point every surface
        // (app, widget, background task) funnels through — and parked in the
        // shared container; only the app process delivers notifications.
        let events = ThresholdEngine.crossings(previous: previous, current: snapshot)
        if !events.isEmpty {
            PendingEventStore(directory: SharedContainer.directory)
                .append(events, accountKey: account.key)
        }
        await scheduler.recordResult(accountKey: account.key, policy: spec.poll, status: status)
        log.info("[\(surface)] \(account.key, privacy: .public): \(status.rawValue, privacy: .public)")
        return Result(snapshot: snapshot, nextAllowed: nil)
    }

    private static func refreshAndRetry(
        spec: ProviderSpec,
        credentials: Credentials,
        account: AccountRef,
        vault: (any CredentialsStore)?,
        surface: String
    ) async -> UsageClient.Outcome? {
        guard let refreshRequest = TokenRefresher.refreshRequest(spec: spec, credentials: credentials) else {
            return nil
        }
        do {
            let (body, response) = try await URLSession.shared.data(for: refreshRequest)
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
                  let updated = TokenRefresher.apply(responseBody: body, to: credentials)
            else {
                log.info("[\(surface)] \(account.key, privacy: .public): token refresh rejected")
                return nil
            }
            try? vault?.save(updated, accountKey: account.key)
            log.info("[\(surface)] \(account.key, privacy: .public): token refreshed, retrying")

            let retry = RequestBuilder.usageRequest(spec: spec, credentials: updated)
            let (data, retryResponse) = try await URLSession.shared.data(for: retry)
            let retryCode = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
            return UsageClient.classify(data: data, statusCode: retryCode, spec: spec)
        } catch {
            // Transport failure mid-refresh: keep the original authExpired —
            // the token WAS rejected; the next cycle can try again.
            return nil
        }
    }
}
