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

    func testCrossingSpanningDegradedPreviousStillFires() {
        // A failed fetch carries the last good windows forward; a crossing
        // that spans the blip (79 -> network error -> 81) must still fire.
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [TestSupport.window("session", 79)], status: .network),
            current: TestSupport.snapshot(windows: [TestSupport.window("session", 81)])
        )
        XCTAssertEqual(events, [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)])
    }
}

final class PendingEventStoreTests: XCTestCase {
    func testAppendMergesAndDrainRemoves() throws {
        let store = PendingEventStore(directory: try TestSupport.tempDirectory())
        let key = "claude:acct"

        store.append([ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)], accountKey: key)
        store.append([
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ], accountKey: key)

        XCTAssertEqual(store.drain(accountKey: key), [
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ], "same window+threshold merges keeping the max utilization")
        XCTAssertTrue(store.drain(accountKey: key).isEmpty, "drain removes the file")
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

final class TokenRefresherTests: XCTestCase {
    private var mintedClaude: Credentials {
        Credentials(
            providerId: "claude",
            accessToken: "sk-ant-oat01-OLD",
            refreshToken: "sk-ant-ort01-R",
            source: TokenRefresher.mintSource
        )
    }

    func testBuildsRefreshRequestForMintedClaude() throws {
        let request = try XCTUnwrap(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.claude, credentials: mintedClaude)
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["grant_type"], "refresh_token")
        XCTAssertEqual(json["refresh_token"], "sk-ant-ort01-R")
        XCTAssertEqual(json["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    func testRefusesNonMintedOrRefreshlessCredentials() {
        var copied = mintedClaude
        copied.source = nil
        XCTAssertNil(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.claude, credentials: copied),
            "copied credentials must never be refreshed (ADR-0005)"
        )

        var refreshless = mintedClaude
        refreshless.refreshToken = nil
        XCTAssertNil(TokenRefresher.refreshRequest(spec: ProviderRegistry.claude, credentials: refreshless))

        let codex = Credentials(
            providerId: "codex", accessToken: "a", refreshToken: "r", source: TokenRefresher.mintSource
        )
        XCTAssertNil(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.codex, credentials: codex),
            "codex has no verified refresh endpoint in v1"
        )
    }

    func testApplyParsesTokenResponse() throws {
        let now = Date(timeIntervalSince1970: 1_784_408_400)
        let body = Data(#"{"access_token":"sk-ant-oat01-NEW","refresh_token":"sk-ant-ort01-NEW","expires_in":28800}"#.utf8)
        let updated = try XCTUnwrap(TokenRefresher.apply(responseBody: body, to: mintedClaude, now: now))
        XCTAssertEqual(updated.accessToken, "sk-ant-oat01-NEW")
        XCTAssertEqual(updated.refreshToken, "sk-ant-ort01-NEW")
        XCTAssertEqual(updated.expiresAt, now.addingTimeInterval(28_800))
        XCTAssertEqual(updated.source, TokenRefresher.mintSource, "source survives the rotation")

        XCTAssertNil(TokenRefresher.apply(responseBody: Data("{}".utf8), to: mintedClaude))
        XCTAssertNil(TokenRefresher.apply(responseBody: Data("not json".utf8), to: mintedClaude))
    }
}
