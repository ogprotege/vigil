import Foundation
import OSLog
import VigilKit

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
        /// Existing snapshot data could not be read safely.
        case snapshotRead
        /// A threshold crossing could not be parked for app delivery.
        case pendingEvents
        /// The shared polling ledger could not be read or written. The string
        /// is safe, user-facing storage context, never credential material.
        case fetchLedger(String)
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
        session: URLSession = .shared,
        persistSnapshot: Bool = true,
        emitThresholdEvents: Bool = true,
        persistRotatedCredentials: Bool = true,
        allowCredentialRefresh: Bool = true,
        pendingEvents: PendingEventStore? = nil
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

        guard await scheduler.acquire(accountKey: account.key, policy: spec.poll) else {
            let acquireError = await scheduler.persistenceErrorDescription()
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
            let schedulerError = await scheduler.persistenceErrorDescription()
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
            let released = await scheduler.release(accountKey: account.key)
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

        do {
            let request = RequestBuilder.usageRequest(spec: spec, credentials: credentials)
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = UsageClient.classify(data: data, statusCode: code, spec: spec)
            status = outcome.status
            planLabel = outcome.planLabel
            windows = outcome.windows
            metrics = outcome.metrics
        } catch {
            // Cancellation (scene ended, BG task expired) is not a provider
            // failure: release the in-flight lock without charging the ledger
            // clock or painting the account "offline".
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                let released = await scheduler.release(accountKey: account.key)
                let schedulerError = released ? nil : await scheduler.persistenceErrorDescription()
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
                persistRotatedCredentials: persistRotatedCredentials
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
                try snapshots.save(snapshot, accountKey: account.key)
            } catch {
                if persistenceIssue == nil {
                    persistenceIssue = .snapshot
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): snapshot save failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
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
                try (pendingEvents ?? PendingEventStore(directory: SharedContainer.directory))
                    .append(events, accountKey: account.key)
            } catch {
                if persistenceIssue == nil {
                    persistenceIssue = .pendingEvents
                }
                log.error(
                    "[\(surface)] \(account.key, privacy: .private(mask: .hash)): pending-event save failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        let recorded = await scheduler.recordResult(accountKey: account.key, policy: spec.poll, status: status)
        if !recorded {
            let schedulerError = await scheduler.persistenceErrorDescription()
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
    }

    private static func refreshAndRetry(
        spec: ProviderSpec,
        credentials: Credentials,
        account: AccountRef,
        vault: (any CredentialsStore)?,
        surface: String,
        session: URLSession,
        persistRotatedCredentials: Bool
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
                    try vault.save(updated, accountKey: account.key)
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

            let retry = RequestBuilder.usageRequest(spec: spec, credentials: updated)
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
}
