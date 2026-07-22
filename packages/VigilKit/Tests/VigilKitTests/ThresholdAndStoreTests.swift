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

    func testDuplicateProviderWindowIDsCannotCrashOrDuplicateNotifications() {
        let events = ThresholdEngine.crossings(
            previous: TestSupport.snapshot(windows: [
                TestSupport.window("session", 79),
                TestSupport.window("session", 5),
            ]),
            current: TestSupport.snapshot(windows: [
                TestSupport.window("session", 81),
                TestSupport.window("session", 99),
            ])
        )

        XCTAssertEqual(
            events,
            [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)]
        )
    }
}

final class PendingEventStoreTests: XCTestCase {
    func testAppendMergesAndDrainRemoves() throws {
        let store = PendingEventStore(directory: try TestSupport.tempDirectory())
        let key = "claude:acct"

        try store.append([ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)], accountKey: key)
        try store.append([
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ], accountKey: key)

        XCTAssertEqual(try store.drain(accountKey: key), [
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ], "same window+threshold merges keeping the max utilization")
        XCTAssertTrue(try store.drain(accountKey: key).isEmpty, "drain removes the file")
    }

    func testConcurrentAppendsDoNotLoseEvents() async throws {
        let directory = try TestSupport.tempDirectory()
        let store = PendingEventStore(directory: directory)
        let key = "claude:concurrent"

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    // Separate values model independently initialized app and
                    // widget processes. Coordination comes only from the file.
                    try PendingEventStore(directory: directory).append(
                        [
                            ThresholdEvent(
                                windowId: "window-\(index)",
                                threshold: 80,
                                utilization: Double(index)
                            ),
                        ],
                        accountKey: key
                    )
                }
            }
            try await group.waitForAll()
        }

        let events = try store.load(accountKey: key)
        XCTAssertEqual(events.count, 64)
        XCTAssertEqual(Set(events.map(\.windowId)), Set((0..<64).map { "window-\($0)" }))
    }

    func testAcknowledgeRemovesOnlyDeliveredEventsAndPreservesNewerValues() throws {
        let store = PendingEventStore(directory: try TestSupport.tempDirectory())
        let key = "claude:ack"
        let delivered = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 81
        )
        try store.append([
            delivered,
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ], accountKey: key)

        // Models a higher observation appended while the older notification
        // is being scheduled.
        try store.append([
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
        ], accountKey: key)
        try store.acknowledge([delivered], accountKey: key)

        XCTAssertEqual(try store.load(accountKey: key), [
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 84),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ])
    }

    func testAcknowledgeDeletesQueueAfterEveryEventIsDelivered() throws {
        let store = PendingEventStore(directory: try TestSupport.tempDirectory())
        let key = "claude:all-delivered"
        let events = [
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 81),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ]
        try store.append(events, accountKey: key)
        try store.acknowledge(events, accountKey: key)
        XCTAssertTrue(try store.load(accountKey: key).isEmpty)
    }

    func testCorruptQueueFailsClosedAndIsPreserved() throws {
        let directory = try TestSupport.tempDirectory()
        let store = PendingEventStore(directory: directory)
        let key = "claude:acct"
        let fileURL = directory.appendingPathComponent("pending-events-claude_acct.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fileURL)

        XCTAssertThrowsError(try store.load(accountKey: key)) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertThrowsError(
            try store.append(
                [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)],
                accountKey: key
            )
        ) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertThrowsError(try store.drain(accountKey: key)) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testDeleteFailureIsReported() throws {
        let directory = try TestSupport.tempDirectory()
        let store = PendingEventStore(directory: directory)
        let fileURL = directory.appendingPathComponent("pending-events-claude_acct.json")
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.delete(accountKey: "claude:acct")) {
            guard case StorePersistenceError.deleteFailed = $0 else {
                return XCTFail("Expected deleteFailed, got \($0)")
            }
        }
    }

    func testUnwritableStorageFailureIsReported() throws {
        let directoryBlocker = try TestSupport.tempDirectory()
            .appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: directoryBlocker)
        let store = PendingEventStore(directory: directoryBlocker)

        XCTAssertThrowsError(
            try store.append(
                [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)],
                accountKey: "claude:acct"
            )
        ) {
            guard case StorePersistenceError.directoryCreationFailed = $0 else {
                return XCTFail("Expected directoryCreationFailed, got \($0)")
            }
        }
    }

}

final class SnapshotStoreTests: XCTestCase {
    func testSaveRotatesCurrentToPrevious() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "claude:acct"

        XCTAssertNil(try store.current(accountKey: key))

        let first = TestSupport.snapshot(windows: [TestSupport.window("session", 10)], accountKey: key)
        try store.save(first, accountKey: key)
        XCTAssertEqual(try store.current(accountKey: key), first)
        XCTAssertNil(try store.previous(accountKey: key))

        let second = TestSupport.snapshot(windows: [TestSupport.window("session", 20)], accountKey: key)
        try store.save(second, accountKey: key)
        XCTAssertEqual(try store.current(accountKey: key), second)
        XCTAssertEqual(try store.previous(accountKey: key), first)
    }

    func testDatesSurviveRoundTrip() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "k"
        let snapshot = TestSupport.snapshot(
            windows: [TestSupport.window("session", 42)],
            accountKey: key
        )
        try store.save(snapshot, accountKey: key)
        let loaded = try XCTUnwrap(try store.current(accountKey: key))
        XCTAssertEqual(loaded.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(loaded.windows.first?.resetsAt, snapshot.windows.first?.resetsAt)
    }

    func testDeleteRemovesBoth() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "k"
        let snapshot = TestSupport.snapshot(windows: [], accountKey: key)
        try store.save(snapshot, accountKey: key)
        try store.save(snapshot, accountKey: key)
        try store.delete(accountKey: key)
        XCTAssertNil(try store.current(accountKey: key))
        XCTAssertNil(try store.previous(accountKey: key))
    }

    func testAccountKeysWithUnsafeCharacters() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())
        let key = "codex:acct/with:odd chars"
        let snapshot = TestSupport.snapshot(windows: [], accountKey: key)
        try store.save(snapshot, accountKey: key)
        XCTAssertEqual(try store.current(accountKey: key), snapshot)
    }

    func testCollidingLegacyFilenameCannotExposeOrOverwriteAnotherAccount() throws {
        let directory = try TestSupport.tempDirectory()
        let store = SnapshotStore(directory: directory)
        let firstKey = "codex:acct/one"
        let collidingKey = "codex:acct_one"
        let first = TestSupport.snapshot(windows: [], accountKey: firstKey)
        let second = TestSupport.snapshot(windows: [], accountKey: collidingKey)
        try store.save(first, accountKey: firstKey)

        XCTAssertThrowsError(try store.current(accountKey: collidingKey)) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertThrowsError(try store.save(second, accountKey: collidingKey)) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertEqual(try store.current(accountKey: firstKey), first)
    }

    func testCorruptCurrentFailsClosedAndIsNotOverwritten() throws {
        let directory = try TestSupport.tempDirectory()
        let store = SnapshotStore(directory: directory)
        let key = "claude:acct"
        let fileURL = directory.appendingPathComponent("snapshot-claude_acct-current.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fileURL)

        XCTAssertThrowsError(try store.current(accountKey: key)) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertThrowsError(
            try store.save(
                TestSupport.snapshot(windows: [], accountKey: key),
                accountKey: key
            )
        ) {
            guard case StorePersistenceError.corruptData = $0 else {
                return XCTFail("Expected corruptData, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testFilesUseOwnerOnlyPermissions() throws {
        let directory = try TestSupport.tempDirectory()
        let snapshotStore = SnapshotStore(directory: directory)
        let pendingStore = PendingEventStore(directory: directory)
        try snapshotStore.save(
            TestSupport.snapshot(windows: [], accountKey: "claude:acct"),
            accountKey: "claude:acct"
        )
        try pendingStore.append(
            [ThresholdEvent(windowId: "session", threshold: 80, utilization: 81)],
            accountKey: "claude:acct"
        )

        let files = [
            directory.appendingPathComponent("snapshot-claude_acct-current.json"),
            directory.appendingPathComponent("snapshot-claude_acct.lock"),
            directory.appendingPathComponent("pending-events-claude_acct.json"),
            directory.appendingPathComponent("pending-events-claude_acct.lock"),
        ]
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, file.lastPathComponent)
#if os(iOS) || os(tvOS) || os(watchOS)
            XCTAssertEqual(
                attributes[.protectionKey] as? FileProtectionType,
                .completeUntilFirstUserAuthentication,
                file.lastPathComponent
            )
#endif
        }
    }

    func testReadTightensLegacyFilePermissions() throws {
        let directory = try TestSupport.tempDirectory()
        let store = SnapshotStore(directory: directory)
        let snapshot = TestSupport.snapshot(windows: [], accountKey: "claude:acct")
        try store.save(snapshot, accountKey: "claude:acct")
        let fileURL = directory.appendingPathComponent("snapshot-claude_acct-current.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )

        XCTAssertEqual(try store.current(accountKey: "claude:acct"), snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testCreatesNestedDirectoryWithOwnerOnlyPermissions() throws {
        let root = try TestSupport.tempDirectory()
        let nested = root.appendingPathComponent("private/store")
        let store = SnapshotStore(directory: nested)
        try store.save(
            TestSupport.snapshot(windows: [], accountKey: "k"),
            accountKey: "k"
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testExistingDirectoryPermissionsAreTightened() throws {
        let directory = try TestSupport.tempDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
        let store = SnapshotStore(directory: directory)

        try store.save(
            TestSupport.snapshot(windows: [], accountKey: "k"),
            accountKey: "k"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testUnwritableStorageFailureIsReported() throws {
        let directoryBlocker = try TestSupport.tempDirectory()
            .appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: directoryBlocker)
        let store = SnapshotStore(directory: directoryBlocker)

        XCTAssertThrowsError(
            try store.save(
                TestSupport.snapshot(windows: [], accountKey: "k"),
                accountKey: "k"
            )
        ) {
            guard case StorePersistenceError.directoryCreationFailed = $0 else {
                return XCTFail("Expected directoryCreationFailed, got \($0)")
            }
        }
    }

    func testDeleteFailureIsReported() throws {
        let directory = try TestSupport.tempDirectory()
        let store = SnapshotStore(directory: directory)
        let currentURL = directory.appendingPathComponent("snapshot-claude_acct-current.json")
        try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.delete(accountKey: "claude:acct")) {
            guard case StorePersistenceError.deleteFailed = $0 else {
                return XCTFail("Expected deleteFailed, got \($0)")
            }
        }
    }

    func testWriteFailureIsReportedWithoutReplacingCurrent() throws {
        let directory = try TestSupport.tempDirectory()
        let store = SnapshotStore(directory: directory)
        let key = "claude:acct"
        let first = TestSupport.snapshot(
            windows: [TestSupport.window("session", 10)],
            accountKey: key
        )
        try store.save(first, accountKey: key)
        let previousURL = directory.appendingPathComponent("snapshot-claude_acct-previous.json")
        try FileManager.default.createDirectory(at: previousURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try store.save(
                TestSupport.snapshot(
                    windows: [TestSupport.window("session", 20)],
                    accountKey: key
                ),
                accountKey: key
            )
        ) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
        XCTAssertEqual(try store.current(accountKey: key), first)
    }

    func testSaveRejectsSnapshotForDifferentAccount() throws {
        let store = SnapshotStore(directory: try TestSupport.tempDirectory())

        XCTAssertThrowsError(
            try store.save(
                TestSupport.snapshot(windows: [], accountKey: "claude:first"),
                accountKey: "claude:second"
            )
        ) {
            guard case StorePersistenceError.writeFailed = $0 else {
                return XCTFail("Expected writeFailed, got \($0)")
            }
        }
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
        XCTAssertEqual(request.timeoutInterval, RequestBuilder.timeoutInterval)
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

        // A manually supplied Codex credential (source "file") must never be
        // refreshed. Only Vigil-minted (device-flow, source "mint") Codex tokens
        // are refresh-owned (ADR-0005), which CodexAuthTests covers.
        let copiedCodex = Credentials(
            providerId: "codex", accessToken: "a", refreshToken: "r", source: "file"
        )
        XCTAssertNil(
            TokenRefresher.refreshRequest(spec: ProviderRegistry.codex, credentials: copiedCodex),
            "copied codex credentials must not be refreshed (ADR-0005)"
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

    func testApplyRejectsOversizedAccessTokenAndIgnoresInvalidExpiry() throws {
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "old",
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let oversized = try JSONSerialization.data(withJSONObject: [
            "access_token": String(repeating: "x", count: 65_537),
        ])
        XCTAssertNil(TokenRefresher.apply(responseBody: oversized, to: credentials))

        let invalidExpiry = try JSONSerialization.data(withJSONObject: [
            "access_token": "new",
            "expires_in": -1,
        ])
        let updated = try XCTUnwrap(
            TokenRefresher.apply(
                responseBody: invalidExpiry,
                to: credentials,
                now: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(updated.accessToken, "new")
        XCTAssertNil(
            updated.expiresAt,
            "an invalid expires_in must clear the expiry — the old date described the replaced token"
        )
    }

    func testApplyRejectsBooleanExpiryAndControlCharacterTokens() throws {
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "old",
            expiresAt: Date(timeIntervalSince1970: 100)
        )

        // JSON true bridges to NSNumber(1) — without the CFBoolean screen it
        // would mint a one-second expiry.
        let booleanExpiry = Data(#"{"access_token":"new","expires_in":true}"#.utf8)
        let updated = try XCTUnwrap(TokenRefresher.apply(responseBody: booleanExpiry, to: credentials))
        XCTAssertNil(updated.expiresAt)

        let controlToken = Data("{\"access_token\":\"bad\\u0000token\"}".utf8)
        XCTAssertNil(
            TokenRefresher.apply(responseBody: controlToken, to: credentials),
            "tokens carrying control characters must be refused"
        )

        // A malformed rotated refresh token is dropped, keeping the previous
        // one, while the access token still applies.
        let controlRefresh = Data("{\"access_token\":\"new\",\"refresh_token\":\"r\\u0007t\"}".utf8)
        var withRefresh = credentials
        withRefresh.refreshToken = "keep-me"
        let applied = try XCTUnwrap(TokenRefresher.apply(responseBody: controlRefresh, to: withRefresh))
        XCTAssertEqual(applied.accessToken, "new")
        XCTAssertEqual(applied.refreshToken, "keep-me")
    }
}
