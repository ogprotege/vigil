import Foundation
import XCTest
@testable import VigilKit

final class ThresholdEngineTests: XCTestCase {
    func testCrossingFires() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 79)]),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 81)])
        )
        XCTAssertEqual(events, [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)])
    }

    func testJumpAcrossMultipleThresholdsFiresEach() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 79)]),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 96)])
        )
        XCTAssertEqual(events.map(\.threshold), [80, 95])
    }

    func testNoEventsWithoutPreviousSnapshot() {
        let events = ThresholdEngine.crossings(
            previous: nil,
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 99)])
        )
        XCTAssertTrue(events.isEmpty, "first fetch after linking must not spam notifications")
    }

    func testWindowResetNeverFires() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 90)]),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 5)])
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testAlreadyAboveThresholdDoesNotRefire() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 85)]),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 90)])
        )
        XCTAssertTrue(events.isEmpty, "80 already crossed earlier; only 95 remains ahead")
    }

    func testWindowsAreIndependent() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 79), TestSupport.window("weekly", 50)]),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 82), TestSupport.window("weekly", 60)])
        )
        XCTAssertEqual(events.map(\.windowId), ["session"])
    }

    func testNonOkSnapshotsProduceNoEvents() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 79)]),
            current: TestSupport.snapshot(windows: [], status: .rateLimited)
        )
        XCTAssertTrue(events.isEmpty)
    }
}

final class SnapshotStoreTests: XCTestCase {
    func testSaveRotatesCurrentToPrevious() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "claude:acct"

        XCTAssertNil(store.current(accountKey: key))

        let first = TestSupport.snapshot(windows: [TestSupport.window("session", 10)], accountKey: key)
        try store.save(first, accountKey: key)
        XCTAssertEqual(store.current(accountKey: key), first)
        XCTAssertNil(store.previous(accountKey: key))

        let second = TestSupport.snapshot(windows: [TestSupport.window("session", 20)], accountKey: key)
        try store.save(second, accountKey: key)
        XCTAssertEqual(store.current(accountKey: key), second)
        XCTAssertEqual(store.previous(accountKey: key), first)
    }

    func testDatesSurviveRoundTrip() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let snapshot = TestSupport.snapshot(windows: [TestSupport.window("session", 42)])
        try store.save(snapshot, accountKey: "k")
        let loaded = try XCTUnwrap(store.current(accountKey: "k"))
        XCTAssertEqual(loaded.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(loaded.windows.first?.resetsAt, snapshot.windows.first?.resetsAt)
    }

    func testDeleteRemovesBoth() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let snapshot = TestSupport.snapshot(windows: [])
        try store.save(snapshot, accountKey: "k")
        try store.save(snapshot, accountKey: "k")
        store.delete(accountKey: "k")
        XCTAssertNil(store.current(accountKey: "k"))
        XCTAssertNil(store.previous(accountKey: "k"))
    }

    func testAccountKeysWithUnsafeCharacters() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "codex:acct/with:odd chars"
        let snapshot = TestSupport.snapshot(windows: [], accountKey: key)
        try store.save(snapshot, accountKey: key)
        XCTAssertEqual(store.current(accountKey: key), snapshot)
    }
}

final class InMemoryVaultTests: XCTestCase {
    func testCrud() throws {
        let vault = InMemoryCredentialsStore()
        let creds = Credentials(providerId: "claude", accessToken: "sk-ant-oat01-X", label: "Claude (max)")
        try vault.save(creds, accountKey: "claude:a")
        XCTAssertEqual(try vault.load(accountKey: "claude:a"), creds)
        XCTAssertEqual(try vault.allKeys(), ["claude:a"])
        try vault.delete(accountKey: "claude:a")
        XCTAssertNil(try vault.load(accountKey: "claude:a"))
    }
}
