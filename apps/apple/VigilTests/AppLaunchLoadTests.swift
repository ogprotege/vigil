import Foundation
import XCTest
import VigilKit
@testable import Vigil

/// AppModel is constructed inside `App.main()` before UIApplicationMain runs.
/// A prewarmed or background-relaunched process can be suspended at any moment
/// during that window, and a held App Group file lock at suspension is a
/// RUNNINGBOARD 0xdead10cc kill — no background-task assertion can exist that
/// early. These tests pin the contract: construction performs no persisted
/// state load, and `ensureLoadedFromDisk()` is the single idempotent
/// post-launch entry point that every launch context routes through.
@MainActor
final class AppLaunchLoadTests: XCTestCase {
    func testInitDoesNotLoadPersistedStateUntilEnsureLoaded() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let key = try await seedLinkedAccount(vault: vault, directory: directory)

        let relaunched = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager()
        )

        XCTAssertFalse(relaunched.hasLoadedFromDisk)
        XCTAssertTrue(
            relaunched.accounts.isEmpty,
            "AppModel.init must not read the account index: it runs before UIApplicationMain where a held App Group lock is a 0xdead10cc kill"
        )
        XCTAssertTrue(relaunched.snapshots.isEmpty)

        relaunched.ensureLoadedFromDisk()

        XCTAssertTrue(relaunched.hasLoadedFromDisk)
        XCTAssertEqual(relaunched.accounts.map(\.key), [key])
        XCTAssertEqual(relaunched.snapshots[key]?.status, .ok)
    }

    func testEnsureLoadedFromDiskLoadsOnlyOnce() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let key = try await seedLinkedAccount(vault: vault, directory: directory)

        let relaunched = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager()
        )
        relaunched.ensureLoadedFromDisk()
        XCTAssertEqual(relaunched.accounts.map(\.key), [key])

        // Mutate the on-disk index behind the model's back so a second
        // ensure call would visibly change state if it re-loaded.
        let secondCredentials = Credentials(providerId: "claude", accessToken: "second-secret")
        let secondKey = AppModel.accountKey(for: secondCredentials)
        try vault.save(secondCredentials, accountKey: secondKey)
        var refs = try AccountIndex.load(from: directory.appendingPathComponent("account-index.json"))
        refs.append(AccountRef(key: secondKey, providerId: "claude", label: nil, plan: nil))
        try AccountIndex.save(refs, to: directory.appendingPathComponent("account-index.json"))

        relaunched.ensureLoadedFromDisk()
        XCTAssertEqual(
            relaunched.accounts.map(\.key),
            [key],
            "ensureLoadedFromDisk must be idempotent — a second call must not re-read disk"
        )

        // Control: a direct loadFromDisk proves the on-disk state did change.
        relaunched.loadFromDisk()
        XCTAssertEqual(Set(relaunched.accounts.map(\.key)), Set([key, secondKey]))
    }

    func testScenePhaseActivationLoadsPersistedState() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let key = try await seedLinkedAccount(vault: vault, directory: directory)

        let relaunched = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager(),
            usageSession: Self.failingStubSession()
        )
        defer { relaunched.scenePhaseChanged(to: .background) }

        relaunched.scenePhaseChanged(to: .active)

        XCTAssertTrue(relaunched.hasLoadedFromDisk)
        XCTAssertEqual(relaunched.accounts.map(\.key), [key])
    }

    func testBackgroundRefreshLoadsPersistedStateBeforeRefreshing() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let key = try await seedLinkedAccount(vault: vault, directory: directory)

        let relaunched = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager(),
            usageSession: Self.failingStubSession()
        )

        // A BGAppRefreshTask relaunch never passes through scene activation;
        // the background path must load persisted accounts itself or the
        // refresh silently refreshes nothing.
        await BackgroundRefresh.performRefresh(model: relaunched)

        XCTAssertTrue(relaunched.hasLoadedFromDisk)
        XCTAssertEqual(relaunched.accounts.map(\.key), [key])
    }

    func testIdentityMutationOnUnloadedModelCannotClobberIndex() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let existingKey = try await seedLinkedAccount(vault: vault, directory: directory)

        let relaunched = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager()
        )
        // Deliberately no ensureLoadedFromDisk(): an index write from an
        // unloaded model must load first or it would silently erase the
        // accounts already on disk.
        let added = Credentials(providerId: "claude", accessToken: "added-later-secret")
        try await relaunched.addAccount(credentials: added, allowUnverified: true)

        let persisted = try AccountIndex.load(
            from: directory.appendingPathComponent("account-index.json")
        )
        XCTAssertEqual(
            Set(persisted.map(\.key)),
            Set([existingKey, AppModel.accountKey(for: added)]),
            "addAccount on an unloaded model must not clobber the persisted index"
        )
    }

    // MARK: - Helpers

    /// Links one Claude account (unverified — no network) and persists a
    /// current snapshot, then returns the account key. State lands in the
    /// account index, Keychain double, and snapshot store exactly as a real
    /// prior session would leave it.
    private func seedLinkedAccount(
        vault: InMemoryCredentialsStore,
        directory: URL
    ) async throws -> String {
        let seeder = AppModel(
            vault: vault,
            directory: directory,
            notifications: NoopNotificationManager()
        )
        let credentials = Credentials(providerId: "claude", accessToken: "launch-secret")
        try await seeder.addAccount(credentials: credentials, allowUnverified: true)
        let key = AppModel.accountKey(for: credentials)
        let snapshot = ProviderSnapshot(
            providerId: "claude",
            accountKey: key,
            accountLabel: nil,
            planLabel: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_753_800_000),
            status: .ok,
            windows: []
        )
        try seeder.snapshotStore.save(snapshot, accountKey: key)
        return key
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-launch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func failingStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaunchTestStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class NoopNotificationManager: NotificationManaging, Sendable {
    func requestAuthorizationIfNeeded() async {}
    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] { [] }
    func removeNotifications(accountKey: String) async {}
    func removeNotifications(identifiers: [String]) async {}
}

/// Fails every request locally so incidental refresh work in these tests can
/// never leave the process.
private final class LaunchTestStubURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.notConnectedToInternet)
        )
    }

    override func stopLoading() {}
}
