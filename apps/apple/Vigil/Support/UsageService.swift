import Foundation
import OSLog
import VigilKit

enum ProviderUsageSession {
    static let shared = make()

    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }
}

/// Removes only this app's legacy default-session storage. Provider requests
/// and OAuth token exchanges now use `ProviderUsageSession`, whose ephemeral
/// configuration neither reads nor writes these stores. Browser cookies from
/// Safari or an OAuth approval surface are outside this process and untouched.
enum LegacyNetworkStorageCleaner {
    static func removeAppScopedSharedSessionData() {
        let legacyCache = URLCache.shared
        legacyCache.removeAllCachedResponses()
        // On current iOS simulators, `removeAllCachedResponses()` can leave a
        // just-written in-memory entry observable through the same cache
        // instance until its storage bookkeeping catches up. Zeroing both
        // capacities forces eviction, and replacing the process-wide default
        // guarantees no legacy response can be reused. Vigil's active network
        // sessions carry their own nil cache, so the zero-capacity default is
        // also the honest steady state for this app.
        legacyCache.memoryCapacity = 0
        legacyCache.diskCapacity = 0
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }
}

/// One ledger-gated fetch: acquire -> request -> classify -> snapshot ->
/// recordResult. Shared by the app, the widget timeline provider, and
/// background refresh so every surface obeys the same budget.
enum UsageService {
    static let log = Logger(subsystem: "app.vigil", category: "fetch")

    enum PersistenceIssue: Sendable {
        /// The provider rotated a refresh token, but the new pair could not be
        /// committed to Keychain. The retry is intentionally not attempted.
        case rotatedCredentials
        /// The provider outcome was received, but its snapshot was not saved.
        case snapshot
        /// A successful provider reading could not be appended to the durable
        /// on-device history. Current usage may still be available.
        case history
        /// Existing snapshot data could not be read safely.
        case snapshotRead
        /// A threshold crossing could not be parked for app delivery.
        case pendingEvents
        /// The shared polling ledger could not be read or written. The string
        /// is safe, user-facing storage context, never credential material.
        case fetchLedger(String)
        /// The shared account-generation registry could not be validated.
        /// Writes stop fail-closed because account removal cannot otherwise be
        /// made atomic across the app and widget processes.
        case accountLifecycle(String)
    }

    enum CredentialState: Sendable, Equatable {
        case unchanged
        case rotated
    }

    struct Result: Sendable {
        let snapshot: ProviderSnapshot?
        /// Non-nil when the ledger refused the fetch.
        let nextAllowed: Date?
        let persistenceIssue: PersistenceIssue?
        /// The pair that produced the final provider outcome. Link
        /// verification can defer persistence, then commit this exact pair.
        let effectiveCredentials: Credentials
        let credentialState: CredentialState
    }

    /// Performs a single gated fetch for one account and persists the outcome.
    /// Returns the saved snapshot, or the ledger's next-allowed time when the
    /// fetch was refused. Never throws — failures degrade into snapshot
    /// statuses per the shared error taxonomy. A 401 on Vigil-minted
    /// credentials triggers one refresh + retry inside the same ledger slot;
    /// by default the rotated pair is persisted to `vault`. Link verification
    /// defers that write so its Keychain and account-index commit stays atomic.
    static func refresh(
        account: AccountRef,
        credentials: Credentials,
        scheduler: FetchScheduler,
        snapshots: SnapshotStore,
        vault: (any CredentialsStore)? = nil,
        surface: String,
        session: URLSession = ProviderUsageSession.shared,
        persistSnapshot: Bool = true,
        emitThresholdEvents: Bool = true,
        persistRotatedCredentials: Bool = true,
        allowCredentialRefresh: Bool = true,
        pendingEvents: PendingEventStore? = nil,
        history: UsageHistoryStore? = nil,
        lifecycle: AccountLifecycleStore? = nil,
        generation: AccountLifecycleGeneration? = nil
    ) async -> Result {
        guard let spec = ProviderRegistry.spec(for: account.providerId) else {
            return Result(
                snapshot: nil,
                nextAllowed: nil,
                persistenceIssue: nil,
                effectiveCredentials: credentials,
                credentialState: .unchanged
            )
        }

        if lifecycle != nil, generation == nil {
            return inactiveResult(credentials: credentials)
        }

        let acquiredLease: FetchLease?
        do {
            acquiredLease = try await schedulerAcquire(
                scheduler,
                policy: spec.poll,
                lifecycle,
                generation: generation,
                accountKey: account.key
            )
        } catch let error as AccountLifecycleError {
            return lifecycleFailureResult(error, credentials: credentials)
        } catch {
            return Result(
                snapshot: nil,
                nextAllowed: nil,
                persistenceIssue: .accountLifecycle(error.localizedDescription),
                effectiveCredentials: credentials,
                credentialState: .unchanged
            )
        }

        guard let lease = acquiredLease else {
            let acquireError = await scheduler.persistenceErrorDescription(accountKey: account.key)
            if let acquireError {
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): ledger acquire failed: \(acquireError, privacy: .private(mask: .hash))"
                )
                return Result(
                    snapshot: nil,
                    nextAllowed: nil,
                    persistenceIssue: .fetchLedger(acquireError),
                    effectiveCredentials: credentials,
                    credentialState: .unchanged
                )
            }
            let next = await scheduler.nextAllowedFetch(accountKey: account.key)
            let schedulerError = await scheduler.persistenceErrorDescription(accountKey: account.key)
            log.info("[\(surface)] \(account.key, privacy: .private(mask: .hash)): ledger refused fetch, next allowed \(next?.description ?? "unknown", privacy: .public)")
            return Result(
                snapshot: nil,
                nextAllowed: next,
                persistenceIssue: schedulerError.map(PersistenceIssue.fetchLedger),
                effectiveCredentials: credentials,
                credentialState: .unchanged
            )
        }

        log.info("[\(surface)] \(account.key, privacy: .private(mask: .hash)): fetching")
        let previous: ProviderSnapshot?
        do {
            previous = try snapshots.current(accountKey: account.key)
        } catch {
            let released: Bool
            do {
                released = try await schedulerRelease(
                    scheduler,
                    lease: lease,
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                )
            } catch let lifecycleError as AccountLifecycleError where isInvalidation(lifecycleError) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: credentials
                )
            } catch {
                return Result(
                    snapshot: nil,
                    nextAllowed: nil,
                    persistenceIssue: .accountLifecycle(error.localizedDescription),
                    effectiveCredentials: credentials,
                    credentialState: .unchanged
                )
            }
            log.error(
                "[\(surface)] \(account.key, privacy: .private(mask: .hash)): snapshot read failed: \(error.localizedDescription, privacy: .private(mask: .hash)); lease released: \(released, privacy: .public)"
            )
            return Result(
                snapshot: nil,
                nextAllowed: nil,
                persistenceIssue: .snapshotRead,
                effectiveCredentials: credentials,
                credentialState: .unchanged
            )
        }
        var status: SnapshotStatus
        var planLabel: String?
        var windows: [UsageWindow]
        var metrics: [UsageMetric]
        var persistenceIssue: PersistenceIssue?
        var effectiveCredentials = credentials
        var credentialState = CredentialState.unchanged
        /// True once the provider has returned an HTTP response of any kind.
        /// Distinguishes "the provider answered" (401/403, 429, 5xx, 2xx that
        /// did not map) from "no request ever reached the provider" (the
        /// credential could not build a request, or the transport failed).
        var providerAnswered = false

        if let request = RequestBuilder.usageRequest(spec: spec, credentials: credentials) {
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // The provider completed a round-trip. Whatever the code says,
                // this request counted against its rate limits and must charge
                // the poll clock — see `shouldChargePollClock` below.
                providerAnswered = true
                let outcome = UsageClient.classify(data: data, statusCode: code, spec: spec)
                status = outcome.status
                planLabel = outcome.planLabel
                windows = outcome.windows
                metrics = outcome.metrics
            } catch {
                // Cancellation (scene ended, BG task expired) is not a provider
                // failure, so the account is not painted "offline" and no
                // snapshot is written. But the request was already dispatched —
                // the bytes are on the wire and counted against the provider's
                // rate limit — so the poll floor must still be charged. A bare
                // release would leave `nextAllowedAt` untouched (`.distantPast`
                // on a fresh account), and because backgrounding the app
                // cancels the refresh task group, a foreground/background cycle
                // could then send one Claude request per cycle with no floor.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    let charged: Bool
                    do {
                        charged = try await schedulerChargeFloor(
                            scheduler,
                            lease: lease,
                            policy: spec.poll,
                            lifecycle,
                            generation: generation,
                            accountKey: account.key
                        )
                    } catch let lifecycleError as AccountLifecycleError where isInvalidation(lifecycleError) {
                        return await retireAndReturnInactive(
                            scheduler: scheduler,
                            lease: lease,
                            policy: spec.poll,
                            accountKey: account.key,
                            credentials: credentials
                        )
                    } catch {
                        return Result(
                            snapshot: nil,
                            nextAllowed: nil,
                            persistenceIssue: .accountLifecycle(error.localizedDescription),
                            effectiveCredentials: credentials,
                            credentialState: .unchanged
                        )
                    }
                    let schedulerError = charged ? nil : await scheduler.persistenceErrorDescription(accountKey: account.key)
                    log.info("[\(surface)] \(account.key, privacy: .private(mask: .hash)): cancelled, released")
                    return Result(
                        snapshot: nil,
                        nextAllowed: nil,
                        persistenceIssue: schedulerError.map(PersistenceIssue.fetchLedger),
                        effectiveCredentials: credentials,
                        credentialState: .unchanged
                    )
                }
                status = .network
                planLabel = nil
                windows = []
                metrics = []
            }
        } else {
            // The URL needs an account id this credential does not carry
            // (GitHub username, xAI team id): the credential cannot
            // authenticate the request — authExpired drives re-link, and the
            // shared taxonomy path below records the outcome normally.
            status = .authExpired
            planLabel = nil
            windows = []
            metrics = []
        }

        // Error taxonomy: 401 -> refresh once -> retry -> else authExpired.
        // Only for credentials Vigil minted (TokenRefresher refuses others).
        // Runs inside the held acquire: one ledger slot covers the 401, the
        // token rotation, and the retry.
        if status == .authExpired, allowCredentialRefresh {
            switch await refreshAndRetry(
                spec: spec,
                credentials: credentials,
                account: account,
                vault: vault,
                surface: surface,
                session: session,
                persistRotatedCredentials: persistRotatedCredentials,
                lifecycle: lifecycle,
                generation: generation
            ) {
            case .outcome(let outcome, let updated):
                effectiveCredentials = updated
                credentialState = .rotated
                status = outcome.status
                planLabel = outcome.planLabel
                windows = outcome.windows
                metrics = outcome.metrics
            case .credentialPersistenceFailed(let updated):
                effectiveCredentials = updated
                credentialState = .rotated
                // A rotated token pair may already have invalidated the
                // previous refresh token. Never claim the fetch recovered and
                // never issue a retry with credentials we failed to preserve.
                persistenceIssue = .rotatedCredentials
                status = .authExpired
                planLabel = nil
                windows = []
                metrics = []
            case .rotatedRetryUnavailable(let updated):
                effectiveCredentials = updated
                credentialState = .rotated
                // The refresh SUCCEEDED and the new pair is committed — only
                // the retry request failed to reach the provider. Leaving the
                // pre-refresh 401's `.authExpired` in place persisted a
                // "Sign-in expired" banner for a sign-in that is actually
                // fine, pushing the user to re-link (which, because the
                // account key fingerprints the now-rotated refresh token,
                // strands a permanent duplicate row). This is the taxonomy's
                // "anything else means network".
                status = .network
                planLabel = nil
                windows = []
                metrics = []
            case .lifecycleInvalidated:
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: credentials
                )
            case .unavailable:
                break
            }
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
                windows: windows,
                metrics: metrics
            )
        } else {
            snapshot = ProviderSnapshot(
                providerId: account.providerId,
                accountKey: account.key,
                accountLabel: account.label,
                planLabel: previous?.planLabel ?? account.plan,
                fetchedAt: previous?.fetchedAt ?? .distantPast,
                status: status,
                windows: previous?.windows ?? [],
                metrics: previous?.metrics ?? []
            )
        }

        if persistSnapshot {
            do {
                _ = try withLifecycle(
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                ) {
                    try snapshots.save(snapshot, accountKey: account.key)
                }
            } catch let error as AccountLifecycleError where isInvalidation(error) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: effectiveCredentials
                )
            } catch {
                if persistenceIssue == nil {
                    persistenceIssue = .snapshot
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): snapshot save failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        // Only accepted provider readings enter history. Degraded snapshots
        // intentionally retain old values, so archiving them would invent a
        // new observation at the time of a network or authentication error.
        if persistSnapshot, snapshot.status == .ok, let history {
            do {
                _ = try withLifecycle(
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                ) {
                    try history.append(snapshot: snapshot)
                }
            } catch let error as AccountLifecycleError where isInvalidation(error) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: effectiveCredentials
                )
            } catch {
                if persistenceIssue == nil {
                    persistenceIssue = .history
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): history append failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        // Crossings are computed here — the single choke point every surface
        // (app, widget, background task) funnels through — and parked in the
        // shared container; only the app process delivers notifications.
        let events = emitThresholdEvents
            ? ThresholdEngine.crossings(previous: previous, current: snapshot)
            : []
        if persistSnapshot, !events.isEmpty {
            do {
                try withLifecycle(
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                ) {
                    try (pendingEvents ?? PendingEventStore(directory: SharedContainer.directory))
                        .append(events, accountKey: account.key)
                }
            } catch let error as AccountLifecycleError where isInvalidation(error) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: effectiveCredentials
                )
            } catch {
                if persistenceIssue == nil {
                    persistenceIssue = .pendingEvents
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): pending-event save failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        // Link verification must not burn the poll floor when no request ever
        // reached the provider — a flaky network or a credential that cannot
        // even build a request was trapping users in the "deferred / save
        // anyway" loop for five minutes with Models / Limits left empty.
        //
        // But any completed round-trip counts against the provider's rate
        // limits, whatever it returned: 401/403, 429, 5xx, and a 2xx whose body
        // did not map are all real requests. Releasing the lease for those
        // would leave `nextAllowedAt` at `.distantPast` on a fresh account and
        // remove the 5-minute Claude floor entirely on the verify path — a
        // documented hard invariant (CLAUDE.md, ADR-0003). So the clock is
        // charged whenever the provider answered.
        let shouldChargePollClock = persistSnapshot || providerAnswered
        if shouldChargePollClock {
            let recorded: Bool
            do {
                recorded = try await schedulerRecordResult(
                    scheduler,
                    lease: lease,
                    policy: spec.poll,
                    status: status,
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                )
            } catch let error as AccountLifecycleError where isInvalidation(error) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: effectiveCredentials
                )
            } catch {
                return Result(
                    snapshot: nil,
                    nextAllowed: nil,
                    persistenceIssue: .accountLifecycle(error.localizedDescription),
                    effectiveCredentials: effectiveCredentials,
                    credentialState: credentialState
                )
            }
            if !recorded {
                let schedulerError = await scheduler.persistenceErrorDescription(accountKey: account.key)
                    ?? "The polling lease changed before the result was recorded."
                if case .rotatedCredentials? = persistenceIssue {
                    // Losing the rotated credential can require a re-link, so keep
                    // that higher-priority user action while logging both faults.
                } else {
                    persistenceIssue = .fetchLedger(schedulerError)
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): ledger result failed: \(schedulerError, privacy: .private(mask: .hash))"
                )
            }
        } else {
            let released: Bool
            do {
                released = try await schedulerRelease(
                    scheduler,
                    lease: lease,
                    lifecycle,
                    generation: generation,
                    accountKey: account.key
                )
            } catch let error as AccountLifecycleError where isInvalidation(error) {
                return await retireAndReturnInactive(
                    scheduler: scheduler,
                    lease: lease,
                    policy: spec.poll,
                    accountKey: account.key,
                    credentials: effectiveCredentials
                )
            } catch {
                return Result(
                    snapshot: nil,
                    nextAllowed: nil,
                    persistenceIssue: .accountLifecycle(error.localizedDescription),
                    effectiveCredentials: effectiveCredentials,
                    credentialState: credentialState
                )
            }
            if !released {
                let schedulerError = await scheduler.persistenceErrorDescription(accountKey: account.key)
                    ?? "The polling lease could not be released after a failed verify."
                if persistenceIssue == nil {
                    persistenceIssue = .fetchLedger(schedulerError)
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): verify release failed: \(schedulerError, privacy: .private(mask: .hash))"
                )
            }
        }
        log.info("[\(surface)] \(account.key, privacy: .private(mask: .hash)): \(status.rawValue, privacy: .public)")
        return Result(
            snapshot: snapshot,
            nextAllowed: nil,
            persistenceIssue: persistenceIssue,
            effectiveCredentials: effectiveCredentials,
            credentialState: credentialState
        )
    }

    private enum RefreshRetryResult {
        case unavailable
        case rotatedRetryUnavailable(Credentials)
        case credentialPersistenceFailed(Credentials)
        case outcome(UsageClient.Outcome, Credentials)
        case lifecycleInvalidated
    }

    private static func refreshAndRetry(
        spec: ProviderSpec,
        credentials: Credentials,
        account: AccountRef,
        vault: (any CredentialsStore)?,
        surface: String,
        session: URLSession,
        persistRotatedCredentials: Bool,
        lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?
    ) async -> RefreshRetryResult {
        guard let refreshRequest = TokenRefresher.refreshRequest(spec: spec, credentials: credentials) else {
            return .unavailable
        }
        do {
            let (body, response) = try await session.data(for: refreshRequest)
            guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
                  let updated = TokenRefresher.apply(responseBody: body, to: credentials)
            else {
                log.info(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): token refresh rejected"
                )
                return .unavailable
            }

            if persistRotatedCredentials {
                guard let vault else {
                    log.error(
                        "[\(surface)] \(account.key, privacy: .private(mask: .hash)): no vault available for rotated credentials"
                    )
                    return .credentialPersistenceFailed(updated)
                }
                do {
                    try withLifecycle(
                        lifecycle,
                        generation: generation,
                        accountKey: account.key
                    ) {
                        try vault.save(updated, accountKey: account.key)
                    }
                } catch let error as AccountLifecycleError where isInvalidation(error) {
                    return .lifecycleInvalidated
                } catch {
                    log.error(
                        "[\(surface)] \(account.key, privacy: .private(mask: .hash)): rotated credential save failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    return .credentialPersistenceFailed(updated)
                }
            }
            log.info(
                "[\(surface)] \(account.key, privacy: .private(mask: .hash)): token refreshed, retrying"
            )

            // A refresh never adds an account id, so a nil here means the
            // template gap that produced the 401 persists: stay authExpired.
            guard let retry = RequestBuilder.usageRequest(spec: spec, credentials: updated) else {
                return .unavailable
            }
            do {
                let (data, retryResponse) = try await session.data(for: retry)
                let retryCode = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                return .outcome(
                    UsageClient.classify(data: data, statusCode: retryCode, spec: spec),
                    updated
                )
            } catch {
                return .rotatedRetryUnavailable(updated)
            }
        } catch {
            // Transport failure mid-refresh: keep the original authExpired —
            // the token WAS rejected; the next cycle can try again.
            return .unavailable
        }
    }

    private static func withLifecycle<T>(
        _ lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?,
        accountKey: String,
        _ body: () throws -> T
    ) throws -> T {
        guard let lifecycle else { return try body() }
        guard let generation else { throw AccountLifecycleError.inactiveAccount }
        return try lifecycle.withCurrentGeneration(
            generation,
            accountKey: accountKey,
            body
        )
    }

    private static func schedulerAcquire(
        _ scheduler: FetchScheduler,
        policy: PollPolicy,
        _ lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?,
        accountKey: String
    ) async throws -> FetchLease? {
        guard let lifecycle else {
            return await scheduler.acquireLease(accountKey: accountKey, policy: policy)
        }
        guard let generation else { throw AccountLifecycleError.inactiveAccount }
        return try await scheduler.acquireLease(
            accountKey: accountKey,
            policy: policy,
            lifecycle: lifecycle,
            generation: generation
        )
    }

    private static func schedulerRelease(
        _ scheduler: FetchScheduler,
        lease: FetchLease,
        _ lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?,
        accountKey: String
    ) async throws -> Bool {
        guard let lifecycle else { return await scheduler.release(lease) }
        guard let generation else { throw AccountLifecycleError.inactiveAccount }
        return try await scheduler.release(
            lease,
            lifecycle: lifecycle,
            generation: generation
        )
    }

    private static func schedulerChargeFloor(
        _ scheduler: FetchScheduler,
        lease: FetchLease,
        policy: PollPolicy,
        _ lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?,
        accountKey: String
    ) async throws -> Bool {
        guard let lifecycle else {
            return await scheduler.chargeFloor(lease, policy: policy)
        }
        guard let generation else { throw AccountLifecycleError.inactiveAccount }
        return try await scheduler.chargeFloor(
            lease,
            policy: policy,
            lifecycle: lifecycle,
            generation: generation
        )
    }

    private static func schedulerRecordResult(
        _ scheduler: FetchScheduler,
        lease: FetchLease,
        policy: PollPolicy,
        status: SnapshotStatus,
        _ lifecycle: AccountLifecycleStore?,
        generation: AccountLifecycleGeneration?,
        accountKey: String
    ) async throws -> Bool {
        guard let lifecycle else {
            return await scheduler.recordResult(
                lease,
                policy: policy,
                status: status
            )
        }
        guard let generation else { throw AccountLifecycleError.inactiveAccount }
        return try await scheduler.recordResult(
            lease,
            policy: policy,
            status: status,
            lifecycle: lifecycle,
            generation: generation
        )
    }

    private static func isInvalidation(_ error: AccountLifecycleError) -> Bool {
        switch error {
        case .inactiveAccount, .staleGeneration:
            return true
        case .corruptRegistry, .persistence:
            return false
        }
    }

    private static func lifecycleFailureResult(
        _ error: AccountLifecycleError,
        credentials: Credentials
    ) -> Result {
        if isInvalidation(error) {
            return inactiveResult(credentials: credentials)
        }
        return Result(
            snapshot: nil,
            nextAllowed: nil,
            persistenceIssue: .accountLifecycle(error.localizedDescription),
            effectiveCredentials: credentials,
            credentialState: .unchanged
        )
    }

    private static func inactiveResult(credentials: Credentials) -> Result {
        Result(
            snapshot: nil,
            nextAllowed: nil,
            persistenceIssue: nil,
            effectiveCredentials: credentials,
            credentialState: .unchanged
        )
    }

    /// A generation may be invalidated while this process owns the scheduler
    /// slot. Guarded release/result methods must then fail, but the local owner
    /// still needs retiring or this app/widget process can never fetch that key
    /// again. Charge the normal floor because the request was already sent.
    private static func retireAndReturnInactive(
        scheduler: FetchScheduler,
        lease: FetchLease,
        policy: PollPolicy,
        accountKey: String,
        credentials: Credentials
    ) async -> Result {
        _ = await scheduler.retireInFlightForLifecycleRotation(
            lease,
            policy: policy
        )
        return inactiveResult(credentials: credentials)
    }
}
