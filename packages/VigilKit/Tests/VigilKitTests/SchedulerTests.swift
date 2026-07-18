import Foundation
import XCTest
@testable import VigilKit

final class SchedulerTests: XCTestCase {
    private let policy = ProviderRegistry.claude.poll
    private let key = "claude:test-account"

    private func makeScheduler(clock: ClockBox, store: LedgerStore) -> FetchScheduler {
        FetchScheduler(store: store, now: { clock.now() }, jitter: { _ in 0 })
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
