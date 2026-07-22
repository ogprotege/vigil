import Foundation
import XCTest
import VigilKit
@testable import Vigil

@MainActor
final class AppModelReliabilityTests: XCTestCase {
    func testCredentialFingerprintSeparatesSameProviderAccounts() {
        let first = Credentials(providerId: "claude", accessToken: "first-token")
        let second = Credentials(providerId: "claude", accessToken: "second-token")

        XCTAssertNotEqual(AppModel.accountKey(for: first), AppModel.accountKey(for: second))
        XCTAssertEqual(AppModel.accountKey(for: first), AppModel.accountKey(for: first))
        XCTAssertFalse(AppModel.accountKey(for: first).contains("first-token"))
    }

    func testProviderAccountIDKeepsIdentityStableAcrossTokenRotation() {
        let before = Credentials(
            providerId: "codex",
            accessToken: "old-token",
            accountId: "acct-123"
        )
        let after = Credentials(
            providerId: "codex",
            accessToken: "new-token",
            accountId: "acct-123"
        )

        XCTAssertEqual(AppModel.accountKey(for: before), AppModel.accountKey(for: after))
    }

    func testAppHostedTestsDoNotUseSystemNotificationCenter() {
        XCTAssertFalse(
            NotificationManager.canUseSystemNotifications,
            "App-hosted tests must never present the notification permission UI"
        )
    }

    func testDeliveredPendingNotificationsAreAcknowledged() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let account = AccountRef(
            key: "claude:pending-success",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let events = [
            ThresholdEvent(windowId: "session", threshold: 80, utilization: 82),
            ThresholdEvent(windowId: "weekly", threshold: 95, utilization: 96),
        ]
        try model.pendingEvents.append(events, accountKey: account.key)

        await model.drainPendingEvents(for: account)

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, events)
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
        XCTAssertNil(model.storageErrorMessage)
    }

    func testFailedPendingNotificationsRemainQueuedForRetry() async throws {
        let directory = try makeTemporaryDirectory()
        let failed = ThresholdEvent(
            windowId: "weekly",
            threshold: 95,
            utilization: 96
        )
        let notifications = RecordingNotificationManager(failedEvents: [failed])
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let account = AccountRef(
            key: "claude:pending-failure",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let delivered = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82
        )
        try model.pendingEvents.append([delivered, failed], accountKey: account.key)

        await model.drainPendingEvents(for: account)

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, [delivered, failed])
        XCTAssertEqual(try model.pendingEvents.load(accountKey: account.key), [failed])
        XCTAssertEqual(
            model.storageErrorMessage,
            "Vigil couldn't schedule 1 notification for Claude. They remain queued for retry."
        )
    }

    func testFailedAccountIndexWriteRollsBackNewKeychainItem() async throws {
        let parent = try makeTemporaryDirectory()
        let notADirectory = parent.appendingPathComponent("blocked-storage")
        try Data("file".utf8).write(to: notADirectory)
        let vault = InMemoryCredentialsStore()
        let model = AppModel(vault: vault, directory: notADirectory)
        let credentials = Credentials(providerId: "claude", accessToken: "secret")

        do {
            try await model.addAccount(
                credentials: credentials,
                allowUnverified: true
            )
            XCTFail("Expected account-index persistence to fail")
        } catch {
            XCTAssertTrue(try vault.allKeys().isEmpty)
            XCTAssertTrue(model.accounts.isEmpty)
        }
    }

    func testKeychainDeleteFailureKeepsAccountInUIAndIndex() throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "secret")
        let key = AppModel.accountKey(for: credentials)
        let account = AccountRef(
            key: key,
            providerId: credentials.providerId,
            label: "Work",
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = DeleteFailingCredentialsStore(
            initial: [key: credentials],
            failDelete: true
        )
        let model = AppModel(vault: vault, directory: directory)

        XCTAssertThrowsError(try model.removeAccount(account))
        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ),
            [account]
        )
        XCTAssertEqual(try vault.load(accountKey: key), credentials)
    }

    func testSuccessfulRemovalDeletesCredentialsAndIndex() throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "secret")
        let key = AppModel.accountKey(for: credentials)
        let account = AccountRef(
            key: key,
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)
        let model = AppModel(vault: vault, directory: directory)

        try model.removeAccount(account)

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(try vault.load(accountKey: key))
        XCTAssertTrue(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ).isEmpty
        )
    }

    func testCacheCleanupFailureKeepsAccountVisibleAndIndexedForRetry() throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "secret")
        let key = AppModel.accountKey(for: credentials)
        let account = AccountRef(
            key: key,
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)

        // SnapshotStore removes files with this v1-safe name. A directory at
        // that path makes unlink fail while leaving the store lock usable.
        let safeKey = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("snapshot-\(safeKey)-current.json"),
            withIntermediateDirectories: false
        )
        let model = AppModel(vault: vault, directory: directory)

        XCTAssertThrowsError(try model.removeAccount(account))
        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ),
            [account]
        )
        XCTAssertNil(try vault.load(accountKey: key), "Keychain deletion remains privacy-first")
    }

    func testCorruptAccountIndexThrowsInsteadOfLookingEmpty() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("account-index.json")
        try Data("not-json".utf8).write(to: url)

        XCTAssertThrowsError(try AccountIndex.load(from: url))
    }

    func testAccountIndexRejectsCollidingStorageKeys() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("account-index.json")
        let refs = [
            AccountRef(key: "codex:acct/one", providerId: "codex", label: nil, plan: nil),
            AccountRef(key: "codex:acct_one", providerId: "codex", label: nil, plan: nil),
        ]

        XCTAssertThrowsError(try AccountIndex.save(refs, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptAccountIndexRecoversFromKeychainAndPreservesBadBytes() throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: indexURL)
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "secret",
            label: "Recovered",
            plan: "max"
        )
        let key = AppModel.accountKey(for: credentials)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)

        let model = AppModel(vault: vault, directory: directory)

        XCTAssertTrue(model.accountIndexUsable)
        XCTAssertEqual(model.accounts, [
            AccountRef(
                key: key,
                providerId: "claude",
                label: "Recovered",
                plan: "max"
            ),
        ])
        XCTAssertEqual(try AccountIndex.load(from: indexURL), model.accounts)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("account-index.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corrupt)
    }

    func testCorruptIndexWithNoCredentialsRepairsToEmptyAndPreservesFile() async throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: indexURL)
        let notifications = RecordingNotificationManager()
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )

        XCTAssertTrue(model.accountIndexUsable)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try AccountIndex.load(from: indexURL).isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("account-index.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corrupt)

        try await model.addAccount(
            credentials: Credentials(
                providerId: "claude",
                accessToken: "new-secret"
            ),
            allowUnverified: true
        )
        XCTAssertEqual(model.accounts.count, 1)
        let authorizationRequests = await notifications.authorizationRequestCount()
        XCTAssertEqual(authorizationRequests, 1)
    }

    func testUnrecoverableCorruptIndexBlocksMutationAndPreservesFile() async throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: indexURL)
        let model = AppModel(
            vault: ListingFailingCredentialsStore(),
            directory: directory
        )

        XCTAssertFalse(model.accountIndexUsable)
        do {
            try await model.addAccount(
                credentials: Credentials(
                    providerId: "claude",
                    accessToken: "new-secret"
                ),
                allowUnverified: true
            )
            XCTFail("Expected a damaged index to block linking")
        } catch AppModel.LinkError.persistence {
            XCTAssertEqual(try Data(contentsOf: indexURL), corrupt)
            XCTAssertTrue(model.accounts.isEmpty)
        }
    }

    func testURLTemplateAccountIdRequirementBlocksSaveUntilProvided() async throws {
        // GitHub's {account_id} lives in the usage URL template, not a
        // header — validation must still refuse to store credentials that
        // RequestBuilder could never turn into a request.
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let model = AppModel(vault: vault, directory: directory)

        do {
            try await model.addAccount(
                credentials: Credentials(providerId: "github", accessToken: "token"),
                allowUnverified: true
            )
            XCTFail("Expected the missing GitHub username to be rejected")
        } catch AppModel.LinkError.invalidCredentials {
            XCTAssertTrue(try vault.allKeys().isEmpty)
            XCTAssertTrue(model.accounts.isEmpty)
        }

        try await model.addAccount(
            credentials: Credentials(
                providerId: "github",
                accessToken: "token",
                accountId: "octocat"
            ),
            allowUnverified: true
        )
        XCTAssertEqual(model.accounts.map(\.key), ["github:octocat"])
    }

    func testDeferredRelinkCannotOverwriteExistingCredentialWithoutConsent() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "codex",
            accessToken: "known-good",
            accountId: "acct-123"
        )
        let incoming = Credentials(
            providerId: "codex",
            accessToken: "unverified",
            accountId: "acct-123"
        )
        let key = AppModel.accountKey(for: old)
        let account = AccountRef(
            key: key,
            providerId: "codex",
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: key)
        let model = AppModel(vault: vault, directory: directory)
        _ = await model.scheduler.recordResult(
            accountKey: key,
            policy: ProviderRegistry.codex.poll,
            status: .ok
        )

        do {
            try await model.addAccount(
                credentials: incoming,
                allowUnverified: false,
                allowReplace: true
            )
            XCTFail("Expected the deferred verification to require explicit consent")
        } catch AppModel.LinkError.verificationDeferred(_) {
            XCTAssertEqual(try vault.load(accountKey: key), old)
        }
    }

    func testWidgetAccountSelectionNeverFallsBackAfterConfiguredAccountIsRemoved() {
        let first = AccountRef(
            key: "claude:first",
            providerId: "claude",
            label: "First",
            plan: nil
        )
        let second = AccountRef(
            key: "codex:second",
            providerId: "codex",
            label: "Second",
            plan: nil
        )

        XCTAssertEqual(
            AccountIndex.selected(from: [first, second], accountKey: nil),
            first
        )
        XCTAssertEqual(
            AccountIndex.selected(from: [first, second], accountKey: second.key),
            second
        )
        XCTAssertNil(
            AccountIndex.selected(from: [first], accountKey: second.key)
        )
    }

    func testRotatedTokenSaveFailureStopsRetryAndSurfacesIssue() async throws {
        let directory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let vault = SaveFailingCredentialsStore()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "expired",
            refreshToken: "old-refresh",
            source: TokenRefresher.mintSource
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "claude",
            label: nil,
            plan: nil
        )

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: vault,
            surface: "test",
            session: session
        )

        guard case .rotatedCredentials? = result.persistenceIssue else {
            return XCTFail("Expected rotated credential persistence failure")
        }
        XCTAssertEqual(result.snapshot?.status, .authExpired)
        XCTAssertEqual(vault.saveAttempts, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "usage + refresh, with no unsafe retry")
    }

    func testLinkVerificationDoesNotRotateBeforeAccountTransaction() async throws {
        let directory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let vault = InMemoryCredentialsStore()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "expired",
            refreshToken: "old-refresh",
            source: TokenRefresher.mintSource
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "claude",
            label: nil,
            plan: nil
        )

        let result = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: directory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: directory),
            vault: vault,
            surface: "link-test",
            session: session,
            persistSnapshot: false,
            emitThresholdEvents: false,
            persistRotatedCredentials: false,
            allowCredentialRefresh: false
        )

        XCTAssertEqual(result.snapshot?.status, .authExpired)
        XCTAssertEqual(result.credentialState, .unchanged)
        XCTAssertEqual(result.effectiveCredentials, credentials)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertTrue(try vault.allKeys().isEmpty)
    }

    func testProviderRejectionOnVerifyStillChargesPollFloor() async throws {
        let directory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = Credentials(providerId: "openrouter", accessToken: "bad-key")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "openrouter",
            label: nil,
            plan: nil
        )
        let scheduler = FetchScheduler(
            store: FileLedgerStore(directory: directory),
            jitter: { _ in 0 }
        )

        let first = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "verify",
            session: session,
            persistSnapshot: false,
            emitThresholdEvents: false,
            persistRotatedCredentials: false,
            allowCredentialRefresh: false
        )
        XCTAssertEqual(first.snapshot?.status, .authExpired)

        // A 401 is a completed round-trip: it counted against the provider's
        // rate limits, so it must charge the poll clock. Releasing here would
        // leave a fresh account's `nextAllowedAt` at `.distantPast` and remove
        // the 5-minute floor entirely on the verify path.
        let next = await scheduler.nextAllowedFetch(accountKey: account.key)
        XCTAssertNotNil(next, "A provider 401 must charge the poll clock")
        XCTAssertTrue(
            next! > Date(),
            "A provider 401 must hold the poll floor, not release it"
        )
        let secondAcquire = await scheduler.acquire(
            accountKey: account.key,
            policy: ProviderRegistry.openRouter.poll
        )
        XCTAssertFalse(
            secondAcquire,
            "Immediate re-verify after a provider 401 must stay gated by the poll floor"
        )
    }

    /// The legitimate half of the verify-path fix: when no request ever reached
    /// the provider, nothing was consumed and the user must be able to retry at
    /// once instead of waiting out a five-minute cooldown they never earned.
    func testTransportFailureOnVerifyDoesNotBurnPollFloor() async throws {
        let directory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        StubURLProtocol.failsTransport = true
        defer { StubURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = Credentials(providerId: "openrouter", accessToken: "some-key")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "openrouter",
            label: nil,
            plan: nil
        )
        let scheduler = FetchScheduler(
            store: FileLedgerStore(directory: directory),
            jitter: { _ in 0 }
        )

        let first = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: scheduler,
            snapshots: SnapshotStore(directory: directory),
            vault: nil,
            surface: "verify",
            session: session,
            persistSnapshot: false,
            emitThresholdEvents: false,
            persistRotatedCredentials: false,
            allowCredentialRefresh: false
        )
        XCTAssertEqual(first.snapshot?.status, .network)

        let secondAcquire = await scheduler.acquire(
            accountKey: account.key,
            policy: ProviderRegistry.openRouter.poll
        )
        XCTAssertTrue(
            secondAcquire,
            "A transport failure reached no provider and must not charge the poll floor"
        )
        _ = await scheduler.release(accountKey: account.key)
    }

    func testFallbackCredentialsStoreCopiesLegacyWithoutDeletingIt() throws {
        let primary = InMemoryCredentialsStore()
        let legacy = InMemoryCredentialsStore()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "legacy-secret"
        )
        try legacy.save(credentials, accountKey: "claude:legacy")
        let store = FallbackCredentialsStore(primary: primary, legacy: legacy)

        XCTAssertEqual(
            try store.load(accountKey: "claude:legacy"),
            credentials
        )
        XCTAssertEqual(
            try primary.load(accountKey: "claude:legacy"),
            credentials
        )
        XCTAssertEqual(
            try legacy.load(accountKey: "claude:legacy"),
            credentials,
            "the old item stays until explicit account removal"
        )

        try store.delete(accountKey: "claude:legacy")
        XCTAssertNil(try primary.load(accountKey: "claude:legacy"))
        XCTAssertNil(try legacy.load(accountKey: "claude:legacy"))
    }

    func testSharedKeychainRejectsUnexpandedBuildSetting() {
        XCTAssertNil(
            SharedKeychain.accessGroup(from: [
                SharedKeychain.accessGroupInfoKey: "$(AppIdentifierPrefix)app.vigil.shared",
            ])
        )
        XCTAssertEqual(
            SharedKeychain.accessGroup(from: [
                SharedKeychain.accessGroupInfoKey: "TEAMID.app.vigil.shared",
            ]),
            "TEAMID.app.vigil.shared"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private actor RecordingNotificationManager: NotificationManaging {
    private var authorizationRequests = 0
    private var delivered: [ThresholdEvent] = []
    private let failedEvents: [ThresholdEvent]

    init(failedEvents: [ThresholdEvent] = []) {
        self.failedEvents = failedEvents
    }

    func requestAuthorizationIfNeeded() async {
        authorizationRequests += 1
    }

    func deliver(events: [ThresholdEvent], account: AccountRef) async -> [ThresholdEvent] {
        delivered.append(contentsOf: events)
        return events.filter { failedEvents.contains($0) }
    }

    func authorizationRequestCount() -> Int {
        authorizationRequests
    }

    func deliveredEvents() -> [ThresholdEvent] {
        delivered
    }
}

private enum TestStoreError: Error {
    case deleteFailed
    case saveFailed
}

private final class DeleteFailingCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Credentials]
    private let failDelete: Bool

    init(initial: [String: Credentials], failDelete: Bool) {
        storage = initial
        self.failDelete = failDelete
    }

    func save(_ credentials: Credentials, accountKey: String) throws {
        lock.withLock { storage[accountKey] = credentials }
    }

    func load(accountKey: String) throws -> Credentials? {
        lock.withLock { storage[accountKey] }
    }

    func delete(accountKey: String) throws {
        if failDelete { throw TestStoreError.deleteFailed }
        lock.withLock { storage[accountKey] = nil }
    }

    func allKeys() throws -> [String] {
        lock.withLock { Array(storage.keys) }
    }
}

private final class SaveFailingCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var saveAttempts: Int {
        lock.withLock { attempts }
    }

    func save(_ credentials: Credentials, accountKey: String) throws {
        lock.withLock { attempts += 1 }
        throw TestStoreError.saveFailed
    }

    func load(accountKey: String) throws -> Credentials? { nil }
    func delete(accountKey: String) throws {}
    func allKeys() throws -> [String] { [] }
}

private final class ListingFailingCredentialsStore: CredentialsStore, @unchecked Sendable {
    func save(_ credentials: Credentials, accountKey: String) throws {}
    func load(accountKey: String) throws -> Credentials? { nil }
    func delete(accountKey: String) throws {}
    func allKeys() throws -> [String] { throw TestStoreError.saveFailed }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    private static var transportFails = false

    /// When true the stub fails the connection instead of answering, modelling
    /// "no request ever reached the provider" (airplane mode, DNS failure).
    static var failsTransport: Bool {
        get { lock.withLock { transportFails } }
        set { lock.withLock { transportFails = newValue } }
    }

    static var requestCount: Int {
        lock.withLock { requests }
    }

    static func reset() {
        lock.withLock {
            requests = 0
            transportFails = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        if Self.failsTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let isRefresh = request.url?.path.contains("/oauth/token") == true
        let status = isRefresh ? 200 : 401
        let body = isRefresh
            ? Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
            : Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
