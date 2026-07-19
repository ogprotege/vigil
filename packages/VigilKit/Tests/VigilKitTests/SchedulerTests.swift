import Foundation
import XCTest
@testable import VigilKit

final class SchedulerTests: XCTestCase {
    private let policy = ProviderRegistry.claude.poll
    private let key = "claude:test-account"

    private func makeScheduler(
        clock: ClockBox,
        store: LedgerStore,
        leaseDuration: TimeInterval = 300
    ) -> FetchScheduler {
        FetchScheduler(
            store: store,
            now: { clock.now() },
            jitter: { _ in 0 },
            leaseDuration: leaseDuration
        )
    }

    func testSingleFlightAndMinInterval() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let store = FileLedgerStore(directory: try TestSupport.tempDirectory())
        let scheduler = makeScheduler(clock: clock, store: store)

        let first = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(first)
        let concurrent = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(concurrent, "single-flight must block a second concurrent fetch")

        await scheduler.recordResult(accountKey: key, policy: policy, status: .ok)

        let tooSoon = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(tooSoon, "min poll interval must gate the next fetch")

        clock.advance(by: policy.minSeconds + 1)
        let afterInterval = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(afterInterval)
        await scheduler.release(accountKey: key)
    }

    func test429BackoffDoublesAndCaps() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let store = FileLedgerStore(directory: try TestSupport.tempDirectory())
        let scheduler = makeScheduler(clock: clock, store: store)

        // Consecutive 429s: 900, 1800, 3600, then capped at 3600.
        for expectedBackoff in [900.0, 1800.0, 3600.0, 3600.0] {
            await scheduler.recordResult(accountKey: key, policy: policy, status: .rateLimited)
            let next = await scheduler.nextAllowedFetch(accountKey: key)
            XCTAssertEqual(
                next?.timeIntervalSince(clock.now()),
                expectedBackoff,
                "backoff sequence must double from base and cap at max"
            )
        }

        // A success resets the backoff to the ordinary min interval.
        await scheduler.recordResult(accountKey: key, policy: policy, status: .ok)
        let next = await scheduler.nextAllowedFetch(accountKey: key)
        XCTAssertEqual(next?.timeIntervalSince(clock.now()), policy.minSeconds)
    }

    func testLedgerSharedAcrossSchedulerInstances() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()

        // "App process" records a fetch...
        let appScheduler = makeScheduler(clock: clock, store: FileLedgerStore(directory: directory))
        _ = await appScheduler.acquire(accountKey: key, policy: policy)
        await appScheduler.recordResult(accountKey: key, policy: policy, status: .ok)

        // ...and the "widget process" (fresh scheduler, same App Group dir)
        // must observe the same budget and refuse to double-poll.
        let widgetScheduler = makeScheduler(clock: clock, store: FileLedgerStore(directory: directory))
        let widgetFetch = await widgetScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(widgetFetch, "shared ledger must gate ALL processes, not just one")

        clock.advance(by: policy.minSeconds + 1)
        let later = await widgetScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(later)
        await widgetScheduler.release(accountKey: key)
    }

    func testConcurrentSchedulersAtomicallyAcquireOnlyOneSharedLease() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        let appScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory)
        )
        let widgetScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory)
        )

        async let appFetch = appScheduler.acquire(accountKey: key, policy: policy)
        async let widgetFetch = widgetScheduler.acquire(accountKey: key, policy: policy)
        let results = await [appFetch, widgetFetch]

        XCTAssertEqual(
            results.filter { $0 }.count,
            1,
            "the locked shared transaction must grant exactly one process"
        )

        // Releasing both is safe: only the actual owner may clear the lease.
        await appScheduler.release(accountKey: key)
        await widgetScheduler.release(accountKey: key)
        let afterRelease = await appScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(afterRelease)
        await appScheduler.release(accountKey: key)
    }

    func testExpiredLeaseCanBeReplacedAndStaleOwnerCannotClearReplacement() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        // A deliberately short policy: acquire clamps the lease to the poll
        // floor, so exercising a 30-second lease needs a floor below it.
        let policy = PollPolicy(
            minSeconds: 20, jitterSeconds: 0, backoff429BaseSeconds: 60, backoffMaxSeconds: 120
        )
        let crashedScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory),
            leaseDuration: 30
        )
        let replacementScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory),
            leaseDuration: 30
        )
        let observerScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory),
            leaseDuration: 30
        )

        let initialAcquire = await crashedScheduler.acquire(accountKey: key, policy: policy)
        let blockedByInitialLease = await replacementScheduler.acquire(
            accountKey: key,
            policy: policy
        )
        XCTAssertTrue(initialAcquire)
        XCTAssertFalse(blockedByInitialLease)

        clock.advance(by: 31)
        let replacementAcquire = await replacementScheduler.acquire(
            accountKey: key,
            policy: policy
        )
        XCTAssertTrue(
            replacementAcquire,
            "an expired crash lease must not wedge the account"
        )

        // The old process resumes late. Neither cancellation nor a late result
        // may erase or charge the newer process's lease.
        let staleRelease = await crashedScheduler.release(accountKey: key)
        let staleResult = await crashedScheduler.recordResult(
            accountKey: key,
            policy: policy,
            status: .ok
        )
        let observerBlocked = await observerScheduler.acquire(
            accountKey: key,
            policy: policy
        )
        XCTAssertFalse(staleRelease)
        XCTAssertFalse(staleResult)
        XCTAssertFalse(
            observerBlocked,
            "the replacement lease must still be held"
        )

        let replacementRelease = await replacementScheduler.release(accountKey: key)
        let observerAcquire = await observerScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(replacementRelease)
        XCTAssertTrue(observerAcquire)
        await observerScheduler.release(accountKey: key)
    }

    func testCrashLeaseNeverExpiresFasterThanThePollFloor() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        // A hostile/buggy caller asks for a 1-second lease against the real
        // Claude policy. acquire must clamp to the 300-second poll floor so a
        // crash-looping process cannot poll faster than 5 minutes.
        let crashedScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory),
            leaseDuration: 1
        )
        let retryScheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory),
            leaseDuration: 1
        )

        let initialAcquire = await crashedScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(initialAcquire)
        // Simulated crash: no release, no recordResult.

        clock.advance(by: 60)
        let tooSoon = await retryScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(
            tooSoon,
            "a crashed fetch's lease must hold for the full poll floor, not the requested lease"
        )

        clock.advance(by: 241) // 301 seconds total
        let afterFloor = await retryScheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(afterFloor)
        await retryScheduler.release(accountKey: key)
    }

    func testLegacyLedgerWithoutLeaseFieldsStillDecodes() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        let file = directory.appendingPathComponent("fetch-ledger.json")
        let future = clock.now().addingTimeInterval(60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = [
            key: LegacyLedgerEntry(nextAllowedAt: future, consecutive429: 2)
        ]
        try encoder.encode(legacy).write(to: file)

        let store = FileLedgerStore(directory: directory)
        let decoded = try store.load()[key]
        XCTAssertEqual(decoded?.nextAllowedAt, future)
        XCTAssertEqual(decoded?.consecutive429, 2)
        XCTAssertNil(decoded?.leaseOwner)
        XCTAssertNil(decoded?.leaseExpiresAt)

        let scheduler = makeScheduler(clock: clock, store: store)
        let fetch = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(fetch)
    }

    func testPersistenceFailureFailsClosedAndIsObservable() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let scheduler = makeScheduler(clock: clock, store: FailingLedgerStore())

        let acquired = await scheduler.acquire(accountKey: key, policy: policy)
        let message = await scheduler.persistenceErrorDescription()

        XCTAssertFalse(acquired, "a fetch must not start when its lease cannot be persisted")
        XCTAssertEqual(message, FailingLedgerStore.message)
    }

    func testSemanticallyInvalidLedgerFailsClosedWithoutArithmeticTrap() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        let file = directory.appendingPathComponent("fetch-ledger.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            key: LedgerEntry(
                nextAllowedAt: .distantPast,
                consecutive429: Int.max
            ),
        ]).write(to: file)

        let store = FileLedgerStore(directory: directory)
        XCTAssertThrowsError(try store.load())

        let scheduler = makeScheduler(clock: clock, store: store)
        let acquired = await scheduler.acquire(accountKey: key, policy: policy)
        let persistenceError = await scheduler.persistenceErrorDescription()
        XCTAssertFalse(acquired)
        XCTAssertNotNil(persistenceError)
    }

    func testMaximum429CounterSaturatesAndUsesCappedBackoff() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        let file = directory.appendingPathComponent("fetch-ledger.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            key: LedgerEntry(
                nextAllowedAt: .distantPast,
                consecutive429: 63
            ),
        ]).write(to: file)

        let store = FileLedgerStore(directory: directory)
        let scheduler = makeScheduler(clock: clock, store: store)
        let recorded = await scheduler.recordResult(
            accountKey: key,
            policy: policy,
            status: .rateLimited
        )
        XCTAssertTrue(recorded)
        XCTAssertEqual(try store.load()[key]?.consecutive429, 63)
        let next = await scheduler.nextAllowedFetch(accountKey: key)
        XCTAssertEqual(
            next?.timeIntervalSince(clock.now()),
            policy.backoffMaxSeconds
        )
    }

    func testLedgerAndLockUseOwnerOnlyPermissions() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let directory = try TestSupport.tempDirectory()
        let scheduler = makeScheduler(
            clock: clock,
            store: FileLedgerStore(directory: directory)
        )
        let acquired = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(acquired)

        for name in ["fetch-ledger.json", "fetch-ledger.lock"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o600, name)
        }
        await scheduler.release(accountKey: key)
    }

    func testClearForgetsLedgerStateForRelink() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let store = FileLedgerStore(directory: try TestSupport.tempDirectory())
        let scheduler = makeScheduler(clock: clock, store: store)

        _ = await scheduler.acquire(accountKey: key, policy: policy)
        await scheduler.recordResult(accountKey: key, policy: policy, status: .ok)
        let refused = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertFalse(refused, "inside the min interval the fetch is refused")

        // Account removed -> ledger forgotten -> an immediate re-link can run
        // its live verify instead of inheriting the departed account's clock.
        await scheduler.clear(accountKey: key)
        let afterClear = await scheduler.acquire(accountKey: key, policy: policy)
        XCTAssertTrue(afterClear)
        await scheduler.release(accountKey: key)
    }

    func testJitterStaysWithinPolicyBound() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_408_400))
        let store = FileLedgerStore(directory: try TestSupport.tempDirectory())
        // Real random jitter this time: verify the bound holds.
        let scheduler = FetchScheduler(store: store, now: { clock.now() })

        for _ in 0..<20 {
            await scheduler.recordResult(accountKey: key, policy: policy, status: .ok)
            let next = await scheduler.nextAllowedFetch(accountKey: key)
            let delta = try XCTUnwrap(next?.timeIntervalSince(clock.now()))
            XCTAssertGreaterThanOrEqual(delta, policy.minSeconds)
            XCTAssertLessThanOrEqual(delta, policy.minSeconds + policy.jitterSeconds)
        }
    }
}

private struct LegacyLedgerEntry: Codable {
    let nextAllowedAt: Date
    let consecutive429: Int
}

private struct FailingLedgerStore: LedgerStore {
    static let message = "intentional ledger failure"

    func load() throws -> [String: LedgerEntry] {
        throw NSError(domain: "SchedulerTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: Self.message
        ])
    }

    func update(_ mutation: (inout [String: LedgerEntry]) -> Void) throws {
        throw NSError(domain: "SchedulerTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: Self.message
        ])
    }
}
