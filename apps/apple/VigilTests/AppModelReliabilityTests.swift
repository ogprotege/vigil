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

    func testCodexLiveUsageShapeVerifiesPersistsAndReloadsLinkedAccount() async throws {
        let directory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.respond(
            statusCode: 200,
            body: Data(Self.codexLiveSpendControlBody.utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let vault = InMemoryCredentialsStore()
        let credentials = Credentials(
            providerId: "codex",
            accessToken: "live-shape-access",
            refreshToken: "live-shape-refresh",
            accountId: "acct-live-shape",
            source: TokenRefresher.mintSource
        )
        let accountKey = AppModel.accountKey(for: credentials)
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            usageSession: session
        )

        try await model.addAccount(credentials: credentials)

        XCTAssertEqual(model.accounts.map(\.key), [accountKey])
        XCTAssertEqual(try vault.load(accountKey: accountKey), credentials)
        XCTAssertEqual(model.snapshots[accountKey]?.status, .ok)
        XCTAssertEqual(model.snapshots[accountKey]?.windows.map(\.id), ["session"])
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let linkedAccount = try XCTUnwrap(model.accounts.first)
        let historyReloaded = await waitForHistoryCount(
            1,
            account: linkedAccount,
            model: model
        )
        XCTAssertTrue(
            historyReloaded,
            "The verified reading should finish its asynchronous archive reload before teardown"
        )

        let reloaded = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            usageSession: session
        )
        XCTAssertEqual(reloaded.accounts.map(\.key), [accountKey])
        XCTAssertEqual(reloaded.snapshots[accountKey]?.status, .ok)
        XCTAssertEqual(try vault.load(accountKey: accountKey), credentials)
    }

    func testRelinkRoutesClaudeCodexAndManualProvidersToTargetedFlows() {
        XCTAssertEqual(AddAccountView.relinkRoute(forProviderId: "claude"), .claude)
        XCTAssertEqual(AddAccountView.relinkRoute(forProviderId: "codex"), .codex)
        XCTAssertEqual(AddAccountView.relinkRoute(forProviderId: "openrouter"), .other)
    }

    func testProviderUsageSessionCannotReuseURLCacheAsFreshUsage() {
        let session = ProviderUsageSession.make()

        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.httpCookieStorage)
    }

    func testLegacyNetworkStorageCleanerRemovesOnlyAppScopedSessionResidue() throws {
        let marker = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://vigil-cache-test.invalid/\(marker)"))
        let request = URLRequest(url: url)
        let legacyCache = URLCache.shared
        legacyCache.memoryCapacity = max(legacyCache.memoryCapacity, 1_024 * 1_024)
        legacyCache.storeCachedResponse(
            CachedURLResponse(
                response: URLResponse(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: 2,
                    textEncodingName: nil
                ),
                data: Data("{}".utf8)
            ),
            for: request
        )
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: "vigil-cache-test.invalid",
                .path: "/",
                .name: "VigilLegacy\(marker)",
                .value: "legacy-cookie",
                .secure: "TRUE",
            ])
        )
        HTTPCookieStorage.shared.setCookie(cookie)

        XCTAssertNotNil(legacyCache.cachedResponse(for: request))
        XCTAssertTrue(
            HTTPCookieStorage.shared.cookies(for: url)?.contains {
                $0.name == cookie.name
            } == true
        )

        LegacyNetworkStorageCleaner.removeAppScopedSharedSessionData()

        XCTAssertNil(legacyCache.cachedResponse(for: request))
        XCTAssertNil(URLCache.shared.cachedResponse(for: request))
        XCTAssertEqual(URLCache.shared.memoryCapacity, 0)
        XCTAssertEqual(URLCache.shared.diskCapacity, 0)
        XCTAssertFalse(
            HTTPCookieStorage.shared.cookies(for: url)?.contains {
                $0.name == cookie.name
            } == true
        )
    }

    func testLinkingOpenAIWaitsForExplicitOfficialHistoryImportConsent() async throws {
        let directory = try makeTemporaryDirectory()
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: RecordingNotificationManager()
        )
        let credentials = Credentials(
            providerId: "openai",
            accessToken: "sk-admin-consent-test",
            source: "manual"
        )

        try await model.addAccount(
            credentials: credentials,
            allowUnverified: true
        )
        for _ in 0..<20 { await Task.yield() }

        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(model.officialHistoryImportState(for: account), .idle)
        XCTAssertTrue(
            model.history(for: account).allSatisfy { $0.source != .providerBackfill },
            "Official 365-day history must begin only from the account-detail Import action."
        )
    }

    func testClaudeRelinkPreservesStableVigilAccountKeyAndHistory() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "claude",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            label: "Personal",
            source: TokenRefresher.mintSource
        )
        let replacement = Credentials(
            providerId: "claude",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            source: TokenRefresher.mintSource
        )
        let originalKey = AppModel.accountKey(for: old)
        let account = AccountRef(
            key: originalKey,
            providerId: "claude",
            label: "Personal",
            plan: "Max"
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: originalKey)
        let historyStore = UsageHistoryStore(directory: directory)
        try historyStore.append(snapshot: Self.snapshot(for: account, utilization: 22))
        let model = AppModel(vault: vault, directory: directory)

        try await model.replaceCredentials(
            for: account,
            with: replacement,
            allowUnverified: true
        )

        XCTAssertEqual(model.accounts.map(\.key), [originalKey])
        XCTAssertEqual(model.accounts.first?.label, "Personal")
        XCTAssertEqual(try vault.load(accountKey: originalKey), replacement)
        XCTAssertNil(try vault.load(accountKey: AppModel.accountKey(for: replacement)))
        XCTAssertEqual(try historyStore.load(accountKey: originalKey).count, 1)
    }

    func testManualTokenProviderRelinkPreservesCredentialDerivedAccountKey() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "openrouter",
            accessToken: "old-key",
            label: "Work",
            source: "manual"
        )
        let replacement = Credentials(
            providerId: "openrouter",
            accessToken: "new-key",
            source: "manual"
        )
        let originalKey = AppModel.accountKey(for: old)
        let account = AccountRef(
            key: originalKey,
            providerId: old.providerId,
            label: "Work",
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: originalKey)
        let model = AppModel(vault: vault, directory: directory)
        let preservedNextAllowed = Date().addingTimeInterval(900)
        try FileLedgerStore(directory: directory).update {
            $0[originalKey] = LedgerEntry(
                nextAllowedAt: preservedNextAllowed,
                consecutive429: 0
            )
        }

        try await model.replaceCredentials(
            for: account,
            with: replacement,
            allowUnverified: true
        )

        XCTAssertEqual(model.accounts.map(\.key), [originalKey])
        XCTAssertEqual(model.accounts.first?.label, "Work")
        XCTAssertEqual(try vault.load(accountKey: originalKey), replacement)
        XCTAssertNil(try vault.load(accountKey: AppModel.accountKey(for: replacement)))
        XCTAssertEqual(
            try XCTUnwrap(
                FileLedgerStore(directory: directory).load()[originalKey]?.nextAllowedAt
            ).timeIntervalSince1970,
            preservedNextAllowed.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testCodexRelinkKeepsStableProviderAccountIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "codex",
            accessToken: "old-token",
            refreshToken: "old-refresh",
            accountId: "acct-123",
            source: TokenRefresher.mintSource
        )
        let replacement = Credentials(
            providerId: "codex",
            accessToken: "new-token",
            refreshToken: "new-refresh",
            accountId: "acct-123",
            source: TokenRefresher.mintSource
        )
        let originalKey = AppModel.accountKey(for: old)
        let account = AccountRef(
            key: originalKey,
            providerId: old.providerId,
            label: nil,
            plan: "Plus"
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: originalKey)
        let model = AppModel(vault: vault, directory: directory)
        let preservedNextAllowed = Date().addingTimeInterval(900)
        try FileLedgerStore(directory: directory).update {
            $0[originalKey] = LedgerEntry(
                nextAllowedAt: preservedNextAllowed,
                consecutive429: 0
            )
        }

        try await model.replaceCredentials(
            for: account,
            with: replacement,
            allowUnverified: true
        )

        XCTAssertEqual(model.accounts.map(\.key), ["codex:acct-123"])
        XCTAssertEqual(try vault.load(accountKey: originalKey), replacement)
        XCTAssertEqual(
            try XCTUnwrap(
                FileLedgerStore(directory: directory).load()[originalKey]?.nextAllowedAt
            ).timeIntervalSince1970,
            preservedNextAllowed.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testTargetedRelinkRejectsDifferentProviderAndCodexAccount() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "codex",
            accessToken: "old",
            accountId: "acct-123"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: old),
            providerId: old.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: account.key)
        let model = AppModel(vault: vault, directory: directory)

        do {
            try await model.replaceCredentials(
                for: account,
                with: Credentials(providerId: "claude", accessToken: "wrong"),
                allowUnverified: true
            )
            XCTFail("Expected provider mismatch")
        } catch AppModel.LinkError.providerMismatch {
            XCTAssertEqual(try vault.load(accountKey: account.key), old)
        }

        do {
            try await model.replaceCredentials(
                for: account,
                with: Credentials(
                    providerId: "codex",
                    accessToken: "other",
                    accountId: "acct-999"
                ),
                allowUnverified: true
            )
            XCTFail("Expected provider-account mismatch")
        } catch AppModel.LinkError.providerAccountMismatch {
            XCTAssertEqual(try vault.load(accountKey: account.key), old)
        }
    }

    func testCancellingDelayedAddLeavesEveryAccountStoreUntouched() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let transport = RelinkRaceURLProtocol.makeSession(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        defer {
            transport.gate.resume()
            RelinkRaceURLProtocol.unregister(transport.identifier)
        }
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            usageSession: transport.session
        )
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "cancel-before-add-commit",
            source: "manual"
        )
        let accountKey = AppModel.accountKey(for: credentials)
        let indexURL = directory.appendingPathComponent("account-index.json")

        let linking = Task {
            try await model.addAccount(credentials: credentials)
        }
        let addVerificationPaused = await waitForRelinkRaceRequest(transport.gate)
        XCTAssertTrue(
            addVerificationPaused,
            "The add verification never reached the deterministic pause point"
        )

        linking.cancel()
        transport.gate.resume()
        do {
            try await linking.value
            XCTFail("A canceled add must report structured cancellation")
        } catch is CancellationError {
            // Expected. The assertions below prove cancellation preceded the
            // first durable linked-account mutation.
        }

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try AccountIndex.load(from: indexURL).isEmpty)
        XCTAssertNil(try vault.load(accountKey: accountKey))
        XCTAssertNil(
            try AccountLifecycleStore(directory: directory)
                .captureActiveGeneration(accountKey: accountKey)
        )
        XCTAssertTrue(
            try UsageHistoryStore(directory: directory).load(accountKey: accountKey).isEmpty
        )
    }

    func testFullRecoveryResetInvalidatesAddStillAwaitingVerification() async throws {
        let directory = try makeTemporaryDirectory()
        let vault = InMemoryCredentialsStore()
        let transport = RelinkRaceURLProtocol.makeSession(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        defer {
            transport.gate.resume()
            RelinkRaceURLProtocol.unregister(transport.identifier)
        }
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            usageSession: transport.session
        )
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "must-not-survive-reset",
            source: "manual"
        )
        let accountKey = AppModel.accountKey(for: credentials)
        let linking = Task {
            try await model.addAccount(credentials: credentials)
        }
        let verificationPaused = await waitForRelinkRaceRequest(transport.gate)
        XCTAssertTrue(verificationPaused)

        try Data("corrupt-during-add".utf8).write(
            to: directory.appendingPathComponent("account-lifecycle.json"),
            options: .atomic
        )
        model.loadFromDisk()
        XCTAssertTrue(model.requiresFullLocalDataRecovery)
        try await model.resetAllLocalDataForRecovery()

        transport.gate.resume()
        do {
            try await linking.value
            XCTFail("An add suspended before the reset must never recreate an account")
        } catch AppModel.LinkError.persistence {
            // The reset epoch supersedes the pre-reset identity transaction.
        }

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try vault.allKeys().isEmpty)
        XCTAssertTrue(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ).isEmpty
        )
        XCTAssertTrue(try AccountLifecycleStore(directory: directory).statuses().isEmpty)
        XCTAssertNil(try FileLedgerStore(directory: directory).load()[accountKey])
    }

    func testCancellingDelayedRelinkPreservesEveryAccountStore() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "openrouter",
            accessToken: "known-good-key",
            label: "Work",
            source: "manual"
        )
        let replacement = Credentials(
            providerId: "openrouter",
            accessToken: "cancel-before-relink-commit",
            label: "Changed",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: old),
            providerId: old.providerId,
            label: old.label,
            plan: nil
        )
        let indexURL = directory.appendingPathComponent("account-index.json")
        try AccountIndex.save([account], to: indexURL)
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: account.key)
        let historyStore = UsageHistoryStore(directory: directory)
        try historyStore.append(snapshot: Self.snapshot(for: account, utilization: 37))
        let historyBefore = try historyStore.load(accountKey: account.key)

        let transport = RelinkRaceURLProtocol.makeSession(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        defer {
            transport.gate.resume()
            RelinkRaceURLProtocol.unregister(transport.identifier)
        }
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            usageSession: transport.session
        )
        let lifecycle = AccountLifecycleStore(directory: directory)
        let generationBefore = try XCTUnwrap(
            lifecycle.captureActiveGeneration(accountKey: account.key)
        )

        let relinking = Task {
            try await model.replaceCredentials(for: account, with: replacement)
        }
        let relinkVerificationPaused = await waitForRelinkRaceRequest(transport.gate)
        XCTAssertTrue(
            relinkVerificationPaused,
            "The re-link verification never reached the deterministic pause point"
        )

        relinking.cancel()
        transport.gate.resume()
        do {
            try await relinking.value
            XCTFail("A canceled re-link must report structured cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(try AccountIndex.load(from: indexURL), [account])
        XCTAssertEqual(try vault.load(accountKey: account.key), old)
        XCTAssertEqual(
            try lifecycle.captureActiveGeneration(accountKey: account.key),
            generationBefore
        )
        XCTAssertEqual(
            try historyStore.load(accountKey: account.key),
            historyBefore
        )
    }

    func testRemovalDuringRelinkVerificationCannotRecreateLedgerOrAccount() async throws {
        let directory = try makeTemporaryDirectory()
        let old = Credentials(
            providerId: "openrouter",
            accessToken: "old-key",
            source: "manual"
        )
        let replacement = Credentials(
            providerId: "openrouter",
            accessToken: "new-key",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: old),
            providerId: old.providerId,
            label: "Work",
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(old, accountKey: account.key)

        let relinkTransport = RelinkRaceURLProtocol.makeSession(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        defer {
            relinkTransport.gate.resume()
            RelinkRaceURLProtocol.unregister(relinkTransport.identifier)
        }
        let model = AppModel(
            vault: vault,
            directory: directory,
            usageSession: relinkTransport.session
        )

        let relink = Task {
            try await model.replaceCredentials(for: account, with: replacement)
        }
        let verificationPaused = await waitForRelinkRaceRequest(relinkTransport.gate)
        XCTAssertTrue(verificationPaused)

        try await model.removeAccount(account)
        relinkTransport.gate.resume()

        do {
            try await relink.value
            XCTFail("A re-link whose target was removed must not commit")
        } catch AppModel.LinkError.relinkTargetMissing {
            // Expected: the captured generation was tombstoned while awaiting.
        }

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(try vault.load(accountKey: account.key))
        XCTAssertNil(try FileLedgerStore(directory: directory).load()[account.key])
    }

    func testRelinkRecomputesTargetIndexAfterAnotherAccountIsRemoved() async throws {
        let directory = try makeTemporaryDirectory()
        let firstCredentials = Credentials(providerId: "claude", accessToken: "first")
        let old = Credentials(
            providerId: "openrouter",
            accessToken: "old-key",
            source: "manual"
        )
        let replacement = Credentials(
            providerId: "openrouter",
            accessToken: "new-key",
            source: "manual"
        )
        let first = AccountRef(
            key: AppModel.accountKey(for: firstCredentials),
            providerId: firstCredentials.providerId,
            label: "First",
            plan: nil
        )
        let target = AccountRef(
            key: AppModel.accountKey(for: old),
            providerId: old.providerId,
            label: "Target",
            plan: nil
        )
        try AccountIndex.save(
            [first, target],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(firstCredentials, accountKey: first.key)
        try vault.save(old, accountKey: target.key)

        let relinkTransport = RelinkRaceURLProtocol.makeSession(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        defer {
            relinkTransport.gate.resume()
            RelinkRaceURLProtocol.unregister(relinkTransport.identifier)
        }
        let model = AppModel(
            vault: vault,
            directory: directory,
            usageSession: relinkTransport.session
        )

        let relink = Task {
            try await model.replaceCredentials(for: target, with: replacement)
        }
        let verificationPaused = await waitForRelinkRaceRequest(relinkTransport.gate)
        XCTAssertTrue(verificationPaused)

        try await model.removeAccount(first)
        relinkTransport.gate.resume()
        try await relink.value

        XCTAssertEqual(model.accounts.map(\.key), [target.key])
        XCTAssertEqual(try vault.load(accountKey: target.key), replacement)
    }

    func testAppHostedTestsDoNotUseSystemNotificationCenter() {
        XCTAssertFalse(
            NotificationManager.canUseSystemNotifications,
            "App-hosted tests must never present the notification permission UI"
        )
    }

    func testNotificationIdentifiersHashAccountKeysDeterministically() {
        let accountKey = "claude:credential:private-account-key"
        let event = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82
        )
        let identifier = NotificationManager.notificationIdentifier(
            accountKey: accountKey,
            deliveryScope: "generation-one",
            event: event
        )

        XCTAssertEqual(
            identifier,
            NotificationManager.notificationIdentifier(
                accountKey: accountKey,
                deliveryScope: "generation-one",
                event: event
            )
        )
        XCTAssertTrue(
            identifier.hasPrefix(
                NotificationManager.accountNotificationPrefix(accountKey: accountKey)
            )
        )
        XCTAssertFalse(identifier.contains(accountKey))
        let otherIdentifier = NotificationManager.notificationIdentifier(
            accountKey: "claude:credential:another-account-key",
            deliveryScope: "generation-one",
            event: event
        )
        XCTAssertNotEqual(identifier, otherIdentifier)
        XCTAssertNotEqual(
            identifier,
            NotificationManager.notificationIdentifier(
                accountKey: accountKey,
                deliveryScope: "generation-two",
                event: event
            ),
            "A stale lifecycle must never share a notification identifier with a re-link"
        )
        XCTAssertEqual(
            NotificationManager.notificationIdentifiers(
                forAccountKey: accountKey,
                among: [
                    otherIdentifier,
                    "another-app.notification",
                    "app.vigil.threshold.\(accountKey).session.80",
                    identifier,
                ]
            ),
            ["app.vigil.threshold.\(accountKey).session.80", identifier],
            "Removal must clear current and pre-upgrade identifiers while preserving every other notification"
        )
        XCTAssertEqual(
            NotificationManager.legacyNotificationIdentifiers(
                among: [
                    identifier,
                    otherIdentifier,
                    "another-app.notification",
                    "app.vigil.threshold.\(accountKey).session.80",
                ]
            ),
            ["app.vigil.threshold.\(accountKey).session.80"],
            "Startup migration must remove raw-key identifiers even when the old account no longer exists"
        )
    }

    func testDeliveredPendingNotificationsAreAcknowledged() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let account = AccountRef(
            key: "claude:pending-success",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 82), ("weekly", 96)]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let events = [
            ThresholdEvent(
                windowId: "session",
                threshold: 80,
                utilization: 82,
                observedAt: observedAt,
                resetAt: resetAt
            ),
            ThresholdEvent(
                windowId: "weekly",
                threshold: 95,
                utilization: 96,
                observedAt: observedAt,
                resetAt: resetAt
            ),
        ]
        try model.pendingEvents.append(events, accountKey: account.key)

        await model.drainPendingEvents(
            for: account,
            now: observedAt.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, events)
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
        XCTAssertNil(model.storageErrorMessage)
    }

    func testRemovalDuringNotificationDeliveryClearsTheLateNotification() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = PausingNotificationManager()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "notification-removal-race"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: "claude",
            label: "Personal",
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 82)]
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: notifications
        )
        let event = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82,
            observedAt: observedAt,
            resetAt: resetAt
        )
        try model.pendingEvents.append([event], accountKey: account.key)

        let drain = Task {
            await model.drainPendingEvents(
                for: account,
                now: observedAt.addingTimeInterval(60)
            )
        }
        let deliveryStarted = await waitForNotificationDeliveryStart(notifications)
        XCTAssertTrue(deliveryStarted, "Notification delivery never reached the pause point")

        try await model.removeAccount(account)
        let removalSweep = await notifications.removedAccountKeys()
        XCTAssertEqual(removalSweep, [account.key])

        // Re-link the same stable key and schedule a new-generation request
        // before the old system delivery resumes.
        try await model.addAccount(credentials: credentials, allowUnverified: true)
        let newGeneration = try XCTUnwrap(
            model.lifecycleStore.captureActiveGeneration(accountKey: account.key)
        )
        _ = await notifications.deliver(
            events: [event],
            account: account,
            deliveryScope: newGeneration.notificationScope
        )
        let newIdentifier = NotificationManager.notificationIdentifier(
            accountKey: account.key,
            deliveryScope: newGeneration.notificationScope,
            event: event
        )

        await notifications.resumeDelivery()
        await drain.value

        let allSweeps = await notifications.removedAccountKeys()
        XCTAssertEqual(
            allSweeps,
            [account.key],
            "Stale delivery cleanup must not run a broad sweep against the new lifecycle"
        )
        let exactRemovals = await notifications.removedIdentifiers()
        XCTAssertEqual(exactRemovals.count, 1)
        XCTAssertNotEqual(exactRemovals.first, newIdentifier)
        XCTAssertEqual(model.accounts.map(\.key), [account.key])
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
    }

    func testFullRecoveryWaitsForSuspendedNotificationDeliveryAndPurgesIt() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = PausingNotificationManager()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "notification-reset-race"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Personal",
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 82)]
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: notifications
        )
        let event = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82,
            observedAt: observedAt,
            resetAt: resetAt
        )
        try model.pendingEvents.append([event], accountKey: account.key)

        let drain = Task {
            await model.drainPendingEvents(
                for: account,
                now: observedAt.addingTimeInterval(60)
            )
        }
        let deliveryStarted = await waitForNotificationDeliveryStart(notifications)
        XCTAssertTrue(
            deliveryStarted,
            "Notification delivery never reached the pause point"
        )

        try Data("corrupt-during-notification-delivery".utf8).write(
            to: directory.appendingPathComponent("account-lifecycle.json"),
            options: .atomic
        )
        model.loadFromDisk()
        XCTAssertTrue(model.requiresFullLocalDataRecovery)

        let resetCompleted = AsyncCompletionFlag()
        let reset = Task {
            try await model.resetAllLocalDataForRecovery()
            await resetCompleted.markCompleted()
        }
        let resetStarted = await waitForFullRecoveryResetStart(model)
        XCTAssertTrue(
            resetStarted,
            "Recovery reset never entered its guarded state"
        )
        let completedWhileDeliveryPaused = await resetCompleted.isCompleted()
        XCTAssertFalse(completedWhileDeliveryPaused)
        let sweepsWhileDeliveryPaused = await notifications.removeAllVigilCount()
        XCTAssertEqual(
            sweepsWhileDeliveryPaused,
            0,
            "Recovery must wait for the older delivery before its first sweep"
        )

        await notifications.resumeDelivery()
        await drain.value
        try await reset.value

        let didComplete = await resetCompleted.isCompleted()
        let hasScheduledNotification = await notifications.hasScheduledVigilNotification()
        let finalSweepCount = await notifications.removeAllVigilCount()
        XCTAssertTrue(didComplete)
        XCTAssertFalse(hasScheduledNotification)
        XCTAssertEqual(
            finalSweepCount,
            2,
            "Recovery must sweep after the old delivery and again immediately before success"
        )
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try vault.allKeys().isEmpty)
    }

    func testFailedPendingNotificationsRemainQueuedForRetry() async throws {
        let directory = try makeTemporaryDirectory()
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        let failed = ThresholdEvent(
            windowId: "weekly",
            threshold: 95,
            utilization: 96,
            observedAt: observedAt,
            resetAt: resetAt
        )
        let notifications = RecordingNotificationManager(failedEvents: [failed])
        let account = AccountRef(
            key: "claude:pending-failure",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 82), ("weekly", 96)]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let delivered = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82,
            observedAt: observedAt,
            resetAt: resetAt
        )
        try model.pendingEvents.append([delivered, failed], accountKey: account.key)

        await model.drainPendingEvents(
            for: account,
            now: observedAt.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, [delivered, failed])
        XCTAssertEqual(try model.pendingEvents.load(accountKey: account.key), [failed])
        XCTAssertEqual(
            model.storageErrorMessage,
            "Vigil couldn't schedule 1 notification for Claude. They remain queued for retry."
        )
    }

    func testLegacyPendingEventIsAcknowledgedWithoutDelivery() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let account = AccountRef(
            key: "claude:legacy-pending",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 90)]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        // Missing observedAt/resetAt models a queue written before segment
        // metadata existed. It decodes, but cannot prove which reset it belongs to.
        try model.pendingEvents.append(
            [ThresholdEvent(windowId: "session", threshold: 80, utilization: 90)],
            accountKey: account.key
        )

        await model.drainPendingEvents(
            for: account,
            now: observedAt.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertTrue(deliveredEvents.isEmpty)
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
    }

    func testRecentPendingEventWithoutResetMetadataIsDelivered() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let account = AccountRef(
            key: "openrouter:nil-reset-pending",
            providerId: "openrouter",
            label: nil,
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: nil,
            windows: [("credits", 84)]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let event = ThresholdEvent(
            windowId: "credits",
            threshold: 80,
            utilization: 82,
            observedAt: observedAt
        )
        try model.pendingEvents.append([event], accountKey: account.key)

        await model.drainPendingEvents(
            for: account,
            now: observedAt.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, [event])
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
    }

    func testDrainUsesANewerSharedSnapshotThanItsInMemoryCopy() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let account = AccountRef(
            key: "claude:widget-race-pending",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = observedAt.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt.addingTimeInterval(-60),
            resetAt: resetAt,
            windows: [("session", 79)]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )

        // Simulate a widget fetch after AppModel loaded its in-memory copy.
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: observedAt,
            resetAt: resetAt,
            windows: [("session", 82)]
        )
        let event = ThresholdEvent(
            windowId: "session",
            threshold: 80,
            utilization: 82,
            observedAt: observedAt,
            resetAt: resetAt
        )
        try model.pendingEvents.append([event], accountKey: account.key)

        await model.drainPendingEvents(
            for: account,
            now: observedAt.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, [event])
        XCTAssertEqual(model.snapshots[account.key]?.fetchedAt, observedAt)
        XCTAssertEqual(model.snapshots[account.key]?.windows.first?.utilization, 82)
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
    }

    func testOnlyCurrentCrossedResetSegmentIsDelivered() async throws {
        let directory = try makeTemporaryDirectory()
        let notifications = RecordingNotificationManager()
        let account = AccountRef(
            key: "claude:pending-validation",
            providerId: "claude",
            label: nil,
            plan: nil
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let currentReset = now.addingTimeInterval(3_600)
        try seedPendingSnapshot(
            account: account,
            directory: directory,
            fetchedAt: now,
            resetAt: currentReset,
            windows: [
                ("valid", 82),
                ("expired", 84),
                ("mismatched", 86),
                ("dropped", 72),
            ]
        )
        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: notifications
        )
        let valid = ThresholdEvent(
            windowId: "valid",
            threshold: 80,
            utilization: 82,
            observedAt: now,
            resetAt: currentReset
        )
        let events = [
            valid,
            ThresholdEvent(
                windowId: "expired",
                threshold: 80,
                utilization: 84,
                observedAt: now.addingTimeInterval(-1_801),
                resetAt: currentReset
            ),
            ThresholdEvent(
                windowId: "mismatched",
                threshold: 80,
                utilization: 86,
                observedAt: now,
                resetAt: currentReset.addingTimeInterval(3_600)
            ),
            ThresholdEvent(
                windowId: "dropped",
                threshold: 80,
                utilization: 81,
                observedAt: now,
                resetAt: currentReset
            ),
        ]
        try model.pendingEvents.append(events, accountKey: account.key)

        await model.drainPendingEvents(
            for: account,
            now: now.addingTimeInterval(60)
        )

        let deliveredEvents = await notifications.deliveredEvents()
        XCTAssertEqual(deliveredEvents, [valid])
        XCTAssertTrue(try model.pendingEvents.load(accountKey: account.key).isEmpty)
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

    func testKeychainDeleteFailureKeepsAccountInUIAndIndex() async throws {
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

        do {
            try await model.removeAccount(account)
            XCTFail("Expected Keychain deletion to fail")
        } catch AppModel.LinkError.persistence {
            // Expected. Assertions below verify the rollback state.
        }
        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ),
            [account]
        )
        XCTAssertEqual(try vault.load(accountKey: key), credentials)
    }

    func testSuccessfulRemovalDeletesCredentialsAndIndex() async throws {
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
        let corruptBackup = directory.appendingPathComponent(
            "account-index.corrupt-test.json"
        )
        try Data("retired account metadata".utf8).write(to: corruptBackup)
        let notifications = RecordingNotificationManager()
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: notifications
        )

        try await model.removeAccount(account)

        let removedNotificationAccounts = await notifications.removedAccountKeys()
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(try vault.load(accountKey: key))
        XCTAssertEqual(removedNotificationAccounts, [key])
        XCTAssertTrue(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ).isEmpty
        )
        XCTAssertNil(
            try AccountLifecycleStore(directory: directory).statuses()[key]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptBackup.path))
        let safeKey = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("snapshot-\(safeKey).lock").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("pending-events-\(safeKey).lock").path
            )
        )
    }

    func testStartupPrunesRemovalResidueThatPredatesLifecycleTracking() throws {
        let directory = try makeTemporaryDirectory()
        let departedKey = "claude:credential:departed-beta-account"
        try FileLedgerStore(directory: directory).update {
            $0[departedKey] = LedgerEntry(
                nextAllowedAt: Date().addingTimeInterval(900),
                consecutive429: 0
            )
        }
        let safeKey = departedKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let snapshotLock = directory.appendingPathComponent("snapshot-\(safeKey).lock")
        let pendingLock = directory.appendingPathComponent("pending-events-\(safeKey).lock")
        try Data().write(to: snapshotLock)
        try Data().write(to: pendingLock)

        let model = AppModel(
            vault: InMemoryCredentialsStore(),
            directory: directory,
            notifications: RecordingNotificationManager()
        )

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(try FileLedgerStore(directory: directory).load()[departedKey])
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotLock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingLock.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("fetch-ledger.lock").path
            ),
            "The global scheduler lock is shared infrastructure, not account residue"
        )
    }

    func testRemovalWaitsForLedgerClearBeforeImmediateReaddCanWriteNewState() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "same-key",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let ledger = PausingClearLedgerStore(
            accountKey: account.key,
            initial: [
                account.key: LedgerEntry(
                    nextAllowedAt: Date().addingTimeInterval(600),
                    consecutive429: 0
                ),
            ]
        )
        let scheduler = FetchScheduler(store: ledger, jitter: { _ in 0 })
        let model = AppModel(
            vault: vault,
            directory: directory,
            scheduler: scheduler
        )
        let completion = AsyncCompletionFlag()
        defer { ledger.resumeClear() }

        let removal = Task {
            try await model.removeAccount(account)
            await completion.markCompleted()
        }
        let clearPaused = await waitForLedgerClearStart(ledger)
        XCTAssertTrue(clearPaused, "Removal never reached its ledger transaction")
        let finishedBeforeClear = await completion.isCompleted()
        XCTAssertFalse(
            finishedBeforeClear,
            "Removal must not return while an old ledger clear can still run"
        )

        ledger.resumeClear()
        try await removal.value
        try await model.addAccount(credentials: credentials, allowUnverified: true)

        let acquired = await scheduler.acquire(
            accountKey: account.key,
            policy: ProviderRegistry.openRouter.poll
        )
        XCTAssertTrue(acquired)
        XCTAssertNotNil(try ledger.load()[account.key])
        await Task.yield()
        XCTAssertNotNil(
            try ledger.load()[account.key],
            "no detached removal clear may erase the new lifecycle's poll state"
        )
    }

    func testDuplicateRemovalEndsBeforeFirstCompletesAndCannotEraseReadd() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "duplicate-removal-key",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let ledger = PausingClearLedgerStore(
            accountKey: account.key,
            initial: [
                account.key: LedgerEntry(
                    nextAllowedAt: Date().addingTimeInterval(600),
                    consecutive429: 0
                ),
            ]
        )
        let scheduler = FetchScheduler(store: ledger, jitter: { _ in 0 })
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            scheduler: scheduler
        )
        defer { ledger.resumeClear() }

        let firstRemoval = Task {
            try await model.removeAccount(account)
        }
        let clearPaused = await waitForLedgerClearStart(ledger)
        XCTAssertTrue(clearPaused, "First removal never reached its ledger transaction")
        XCTAssertTrue(model.isRemovingAccount(account.key))

        do {
            try await model.removeAccount(account)
            XCTFail("A duplicate caller must not own or continue removal cleanup")
        } catch AppModel.LinkError.accountRemovalInProgress {
            // Expected: the duplicate ends while the first owner is still paused.
        }

        do {
            try await model.addAccount(credentials: credentials, allowUnverified: true)
            XCTFail("Same-key linking must stay quarantined during removal")
        } catch AppModel.LinkError.accountRemovalInProgress {
            // Expected.
        }

        ledger.resumeClear()
        try await firstRemoval.value
        XCTAssertFalse(model.isRemovingAccount(account.key))

        try await model.addAccount(credentials: credentials, allowUnverified: true)
        await Task.yield()

        XCTAssertEqual(model.accounts.map(\.key), [account.key])
        XCTAssertEqual(try vault.load(accountKey: account.key), credentials)
        XCTAssertEqual(
            try AccountLifecycleStore(directory: directory).statuses()[account.key],
            .active
        )
    }

    func testFullRecoveryWaitsForSuspendedRemovalBeforeAllowingReadd() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "removal-reset-race",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let notifications = PausingRemovalNotificationManager()
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: notifications
        )
        defer { Task { await notifications.resumeRemoval() } }

        let removal = Task {
            try await model.removeAccount(account)
        }
        let removalPaused = await waitForRemovalNotificationStart(notifications)
        XCTAssertTrue(removalPaused)

        try Data("corrupt-while-removal-paused".utf8).write(
            to: directory.appendingPathComponent("account-lifecycle.json"),
            options: .atomic
        )
        model.loadFromDisk()
        XCTAssertTrue(model.requiresFullLocalDataRecovery)

        let resetCompleted = AsyncCompletionFlag()
        let reset = Task {
            try await model.resetAllLocalDataForRecovery()
            await resetCompleted.markCompleted()
        }
        let resetStarted = await waitForFullRecoveryResetStart(model)
        XCTAssertTrue(
            resetStarted,
            "Recovery reset never entered its guarded state"
        )
        let didResetBeforeRemovalReturned = await resetCompleted.isCompleted()
        XCTAssertFalse(
            didResetBeforeRemovalReturned,
            "Recovery must wait for an older account-wide cleanup call to return"
        )

        await notifications.resumeRemoval()
        do {
            try await removal.value
            XCTFail("The pre-reset removal must be superseded")
        } catch AppModel.LinkError.persistence {
            // Expected after the reset epoch changes.
        }
        try await reset.value

        try await model.addAccount(credentials: credentials, allowUnverified: true)
        XCTAssertEqual(model.accounts.map(\.key), [account.key])
        XCTAssertEqual(try vault.load(accountKey: account.key), credentials)
        XCTAssertEqual(
            try AccountLifecycleStore(directory: directory).statuses()[account.key],
            .active
        )
    }

    func testStartupRetirementBlocksReaddUntilDelayedLedgerClearFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "interrupted-removal-key",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let lifecycle = AccountLifecycleStore(directory: directory)
        _ = try lifecycle.beginNewLifecycle(accountKey: account.key)
        try lifecycle.tombstone(accountKey: account.key)
        let ledger = PausingClearLedgerStore(
            accountKey: account.key,
            initial: [
                account.key: LedgerEntry(
                    nextAllowedAt: Date().addingTimeInterval(600),
                    consecutive429: 0
                ),
            ]
        )
        let scheduler = FetchScheduler(store: ledger, jitter: { _ in 0 })
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager(),
            scheduler: scheduler
        )
        defer { ledger.resumeClear() }

        let startupClearPaused = await waitForLedgerClearStart(ledger)
        XCTAssertTrue(startupClearPaused)
        do {
            try await model.addAccount(
                credentials: credentials,
                allowUnverified: true
            )
            XCTFail("Re-link must wait for the startup retirement tail")
        } catch AppModel.LinkError.persistence {
            XCTAssertTrue(model.accounts.isEmpty)
            XCTAssertNil(try vault.load(accountKey: account.key))
        }

        ledger.resumeClear()
        var retirementFinished = false
        for _ in 0..<200 {
            if try lifecycle.statuses()[account.key] == nil {
                retirementFinished = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(retirementFinished)

        try await model.addAccount(
            credentials: credentials,
            allowUnverified: true
        )
        let acquired = await scheduler.acquire(
            accountKey: account.key,
            policy: ProviderRegistry.openRouter.poll
        )
        XCTAssertTrue(acquired)
        XCTAssertNotNil(try ledger.load()[account.key])
    }

    func testLedgerClearFailurePreventsRemovalFromReportingSuccess() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "secret")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: nil,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let scheduler = FetchScheduler(
            store: UpdateFailingLedgerStore(
                initial: [
                    account.key: LedgerEntry(
                        nextAllowedAt: Date().addingTimeInterval(600),
                        consecutive429: 0
                    ),
                ]
            )
        )
        let model = AppModel(
            vault: vault,
            directory: directory,
            scheduler: scheduler
        )

        do {
            try await model.removeAccount(account)
            XCTFail("A failed ledger clear must fail the removal transaction")
        } catch AppModel.LinkError.persistence {
            XCTAssertEqual(model.accounts, [account])
            XCTAssertEqual(
                try AccountIndex.load(
                    from: directory.appendingPathComponent("account-index.json")
                ),
                [account]
            )
        }
    }

    func testCacheCleanupFailureKeepsAccountVisibleAndIndexedForRetry() async throws {
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

        do {
            try await model.removeAccount(account)
            XCTFail("Expected cache cleanup to fail")
        } catch AppModel.LinkError.persistence {
            // Expected. Assertions below verify the privacy-first state.
        }
        XCTAssertEqual(model.accounts, [account])
        XCTAssertEqual(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ),
            [account]
        )
        XCTAssertNil(try vault.load(accountKey: key), "Keychain deletion remains privacy-first")
    }

    func testCorruptHistoryOffersExplicitAllHistoryRecoveryAndFinishesRemoval() async throws {
        let directory = try makeTemporaryDirectory()
        let firstCredentials = Credentials(providerId: "claude", accessToken: "first-secret")
        let secondCredentials = Credentials(providerId: "codex", accessToken: "second-secret")
        let first = AccountRef(
            key: AppModel.accountKey(for: firstCredentials),
            providerId: firstCredentials.providerId,
            label: "First",
            plan: nil
        )
        let second = AccountRef(
            key: AppModel.accountKey(for: secondCredentials),
            providerId: secondCredentials.providerId,
            label: "Second",
            plan: nil
        )
        try AccountIndex.save(
            [first, second],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(firstCredentials, accountKey: first.key)
        try vault.save(secondCredentials, accountKey: second.key)
        let historyStore = UsageHistoryStore(directory: directory)
        try historyStore.append(snapshot: Self.snapshot(for: first, utilization: 22))
        try historyStore.append(snapshot: Self.snapshot(for: second, utilization: 44))

        // Model startup sees valid history. Corrupt it afterward so removal is
        // the first operation forced to choose between preserving and erasing.
        let model = AppModel(vault: vault, directory: directory)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("usage-history-v1.json"),
            options: .atomic
        )

        do {
            try await model.removeAccount(first)
            XCTFail("Damaged history must require explicit all-history recovery")
        } catch AppModel.LinkError.historyRecoveryRequired(_) {
            XCTAssertEqual(model.accounts, [first, second])
            XCTAssertNil(try vault.load(accountKey: first.key))
            XCTAssertEqual(try vault.load(accountKey: second.key), secondCredentials)
        }

        try await model.finishRemovalByDeletingAllHistory(first)

        XCTAssertEqual(model.accounts, [second])
        XCTAssertTrue(try historyStore.load().isEmpty)
        XCTAssertNil(try vault.load(accountKey: first.key))
        XCTAssertEqual(try vault.load(accountKey: second.key), secondCredentials)
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
        XCTAssertTrue(model.hasAccountRepairBackups)

        try model.deleteAccountRepairBackups()

        XCTAssertFalse(model.hasAccountRepairBackups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups[0].path))
    }

    func testValidEmptyIndexRecoversActiveCredentialMissingFromIndex() throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        try AccountIndex.save([], to: indexURL)
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "interrupted-link",
            label: "Recovered link"
        )
        let key = AppModel.accountKey(for: credentials)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)
        _ = try AccountLifecycleStore(directory: directory)
            .beginNewLifecycle(accountKey: key)

        let model = AppModel(vault: vault, directory: directory)

        XCTAssertEqual(model.accounts.map(\.key), [key])
        XCTAssertEqual(try AccountIndex.load(from: indexURL), model.accounts)
        XCTAssertNotNil(model.storageErrorMessage)
    }

    func testMissingIndexRecoversKeychainCredentialAfterReinstall() throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "codex",
            accessToken: "surviving-keychain-item",
            accountId: "acct-reinstalled",
            label: "Recovered install"
        )
        let key = AppModel.accountKey(for: credentials)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)

        let model = AppModel(vault: vault, directory: directory)

        XCTAssertEqual(model.accounts.map(\.key), [key])
        XCTAssertEqual(
            try AccountIndex.load(from: directory.appendingPathComponent("account-index.json")),
            model.accounts
        )
        XCTAssertEqual(
            try AccountLifecycleStore(directory: directory).statuses()[key],
            .active
        )
    }

    func testTombstonedOrphanCredentialIsDeletedInsteadOfResurrected() throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "remove-me")
        let key = AppModel.accountKey(for: credentials)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: key)
        let lifecycle = AccountLifecycleStore(directory: directory)
        _ = try lifecycle.beginNewLifecycle(accountKey: key)
        try lifecycle.tombstone(accountKey: key)

        let model = AppModel(vault: vault, directory: directory)

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(try vault.load(accountKey: key))
    }

    func testFailedOrphanTombstoneCleanupBlocksSameKeyRelink() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "blocked-relink")
        let key = AppModel.accountKey(for: credentials)
        let lifecycle = AccountLifecycleStore(directory: directory)
        _ = try lifecycle.beginNewLifecycle(accountKey: key)
        try lifecycle.tombstone(accountKey: key)
        let safeKey = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // A directory at the snapshot payload path makes unlink fail while
        // leaving the account absent from both index and Keychain.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("snapshot-\(safeKey)-current.json"),
            withIntermediateDirectories: false
        )
        let vault = InMemoryCredentialsStore()
        let model = AppModel(vault: vault, directory: directory)

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNotNil(model.storageErrorMessage)
        do {
            try await model.addAccount(
                credentials: credentials,
                allowUnverified: true
            )
            XCTFail("A failed invisible tombstone cleanup must block re-link")
        } catch AppModel.LinkError.persistence {
            XCTAssertNil(try vault.load(accountKey: key))
            XCTAssertEqual(try lifecycle.statuses()[key], .tombstoned)
        }
    }

    func testIndexedTombstoneFinishesInterruptedRemovalOnLaunch() throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        let credentials = Credentials(providerId: "claude", accessToken: "partial-removal")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Interrupted removal",
            plan: nil
        )
        try AccountIndex.save([account], to: indexURL)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let lifecycle = AccountLifecycleStore(directory: directory)
        _ = try lifecycle.beginNewLifecycle(accountKey: account.key)
        try lifecycle.tombstone(accountKey: account.key)
        try SnapshotStore(directory: directory).save(
            Self.snapshot(for: account, utilization: 88),
            accountKey: account.key
        )

        let model = AppModel(vault: vault, directory: directory)

        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try AccountIndex.load(from: indexURL).isEmpty)
        XCTAssertNil(try vault.load(accountKey: account.key))
        XCTAssertNil(try SnapshotStore(directory: directory).current(accountKey: account.key))
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

    func testFullRecoveryResetReplacesCorruptLifecycleAndDeletesAllLocalData() async throws {
        let directory = try makeTemporaryDirectory()
        let priorFallbackDirectory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "recovery-secret",
            label: "Damaged lifecycle"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: credentials.label,
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        try SnapshotStore(directory: directory).save(
            Self.snapshot(for: account, utilization: 73),
            accountKey: account.key
        )
        try UsageHistoryStore(directory: directory).append(
            snapshot: Self.snapshot(for: account, utilization: 73)
        )
        try PendingEventStore(directory: directory).append(
            [ThresholdEvent(windowId: "session", threshold: 80, utilization: 82)],
            accountKey: account.key
        )
        try FileLedgerStore(directory: directory).update {
            $0[account.key] = LedgerEntry(
                nextAllowedAt: Date().addingTimeInterval(600),
                consecutive429: 0
            )
        }
        try AccountIndex.save(
            [account],
            to: priorFallbackDirectory.appendingPathComponent("account-index.json")
        )
        _ = try AccountLifecycleStore(directory: priorFallbackDirectory)
            .beginNewLifecycle(accountKey: account.key)
        try SnapshotStore(directory: priorFallbackDirectory).save(
            Self.snapshot(for: account, utilization: 61),
            accountKey: account.key
        )
        try UsageHistoryStore(directory: priorFallbackDirectory).append(
            snapshot: Self.snapshot(for: account, utilization: 61)
        )
        try FileLedgerStore(directory: priorFallbackDirectory).update {
            $0[account.key] = LedgerEntry(
                nextAllowedAt: Date().addingTimeInterval(300),
                consecutive429: 0
            )
        }
        try Data("not-a-lifecycle-registry".utf8).write(
            to: directory.appendingPathComponent("account-lifecycle.json"),
            options: .atomic
        )
        let notifications = RecordingNotificationManager()
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: notifications,
            additionalRecoveryDirectories: [priorFallbackDirectory]
        )

        XCTAssertFalse(model.accountIndexUsable)
        XCTAssertTrue(model.requiresFullLocalDataRecovery)

        try await model.resetAllLocalDataForRecovery()

        XCTAssertTrue(model.accountIndexUsable)
        XCTAssertFalse(model.requiresFullLocalDataRecovery)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertTrue(try vault.allKeys().isEmpty)
        XCTAssertTrue(
            try AccountIndex.load(
                from: directory.appendingPathComponent("account-index.json")
            ).isEmpty
        )
        XCTAssertTrue(try AccountLifecycleStore(directory: directory).statuses().isEmpty)
        XCTAssertNil(try SnapshotStore(directory: directory).current(accountKey: account.key))
        XCTAssertTrue(try PendingEventStore(directory: directory).load(accountKey: account.key).isEmpty)
        XCTAssertTrue(try UsageHistoryStore(directory: directory).load().isEmpty)
        XCTAssertTrue(try FileLedgerStore(directory: directory).load().isEmpty)
        XCTAssertTrue(
            try AccountIndex.load(
                from: priorFallbackDirectory.appendingPathComponent("account-index.json")
            ).isEmpty
        )
        XCTAssertTrue(
            try AccountLifecycleStore(directory: priorFallbackDirectory).statuses().isEmpty
        )
        XCTAssertNil(
            try SnapshotStore(directory: priorFallbackDirectory).current(
                accountKey: account.key
            )
        )
        XCTAssertTrue(
            try UsageHistoryStore(directory: priorFallbackDirectory).load().isEmpty
        )
        XCTAssertTrue(try FileLedgerStore(directory: priorFallbackDirectory).load().isEmpty)
        let removedAllNotifications = await notifications.didRemoveAllVigilNotifications()
        XCTAssertTrue(removedAllNotifications)
    }

    func testFullRecoveryResetDeletesUnreadableCredentialAfterCorruptIndex() async throws {
        let directory = try makeTemporaryDirectory()
        let indexURL = directory.appendingPathComponent("account-index.json")
        try Data("not-an-account-index".utf8).write(to: indexURL)
        let key = "claude:credential:unreadable"
        let vault = UnreadableCredentialsStore(accountKey: key)
        let model = AppModel(
            vault: vault,
            directory: directory,
            notifications: RecordingNotificationManager()
        )

        XCTAssertFalse(model.accountIndexUsable)
        XCTAssertTrue(model.requiresFullLocalDataRecovery)

        try await model.resetAllLocalDataForRecovery()

        XCTAssertTrue(try vault.allKeys().isEmpty)
        XCTAssertTrue(model.accountIndexUsable)
        XCTAssertFalse(model.requiresFullLocalDataRecovery)
        XCTAssertTrue(try AccountIndex.load(from: indexURL).isEmpty)
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

        let opaqueSecond = OpaqueAccountIdentifier.widgetID(for: second.key)
        XCTAssertFalse(opaqueSecond.contains(second.key))
        XCTAssertEqual(
            AccountIndex.selectedForWidget(
                from: [first, second],
                identifier: opaqueSecond
            ),
            second
        )
        XCTAssertEqual(
            AccountIndex.selectedForWidget(
                from: [first, second],
                identifier: second.key
            ),
            second,
            "Legacy raw widget identifiers remain a read-only migration bridge"
        )
        XCTAssertNil(
            AccountIndex.selectedForWidget(
                from: [first],
                identifier: opaqueSecond
            ),
            "A removed widget account must stay empty instead of falling back"
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
        // the poll floor entirely on the verify path.
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
    /// once instead of waiting out a poll-floor cooldown they never earned.
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

    func testSuccessfulFetchArchivesHistoryButProviderFailureDoesNot() async throws {
        let successDirectory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        StubURLProtocol.respond(
            statusCode: 200,
            body: Data(Self.openRouterSuccessBody.utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = Credentials(providerId: "openrouter", accessToken: "test-key")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Test",
            plan: nil
        )
        let successHistory = UsageHistoryStore(directory: successDirectory)

        let success = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: successDirectory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: successDirectory),
            surface: "history-success-test",
            session: session,
            history: successHistory
        )

        XCTAssertEqual(success.snapshot?.status, .ok)
        let archived = try successHistory.load(accountKey: account.key)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.source, .observed)
        XCTAssertEqual(archived.first?.metrics.first?.kind, .spend)

        let failureDirectory = try makeTemporaryDirectory()
        StubURLProtocol.reset()
        let failed = await UsageService.refresh(
            account: account,
            credentials: credentials,
            scheduler: FetchScheduler(
                store: FileLedgerStore(directory: failureDirectory),
                jitter: { _ in 0 }
            ),
            snapshots: SnapshotStore(directory: failureDirectory),
            surface: "history-failure-test",
            session: session,
            history: UsageHistoryStore(directory: failureDirectory)
        )

        XCTAssertEqual(failed.snapshot?.status, .authExpired)
        XCTAssertTrue(
            try UsageHistoryStore(directory: failureDirectory).load().isEmpty,
            "A failed fetch must not archive retained or empty values as a new reading"
        )
    }

    func testAppReconcilesWidgetHistoryAndRemovalDeletesIt() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(providerId: "claude", accessToken: "secret")
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Personal",
            plan: nil
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let model = AppModel(vault: vault, directory: directory)
        let externallyWritten = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: nil,
            fetchedAt: Date(),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: 42,
                    resetsAt: Date().addingTimeInterval(3_600),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
        try UsageHistoryStore(directory: directory).append(snapshot: externallyWritten)

        XCTAssertTrue(model.history(for: account).isEmpty)
        model.reconcileSharedData()
        let didLoadHistory = await waitForHistoryCount(1, account: account, model: model)
        XCTAssertTrue(didLoadHistory)
        XCTAssertEqual(model.history(for: account).count, 1)

        try await model.removeAccount(account)

        XCTAssertTrue(try UsageHistoryStore(directory: directory).load().isEmpty)
        XCTAssertTrue(model.recentHistorySamples.isEmpty)
        XCTAssertTrue(model.historySummaries.isEmpty)
    }

    func testRemovalTombstoneBlocksInFlightAppRefreshFromRecreatingAnyStore() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "claude",
            accessToken: "expired-access",
            refreshToken: "old-refresh",
            source: TokenRefresher.mintSource
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Personal",
            plan: "Max"
        )
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let oldSnapshot = Self.snapshot(for: account, utilization: 70)
        try SnapshotStore(directory: directory).save(oldSnapshot, accountKey: account.key)
        try UsageHistoryStore(directory: directory).append(snapshot: oldSnapshot)
        try PendingEventStore(directory: directory).append(
            [ThresholdEvent(windowId: "session", threshold: 80, utilization: 85)],
            accountKey: account.key
        )
        StubURLProtocol.reset()
        StubURLProtocol.pauseResponses()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel(
            vault: vault,
            directory: directory,
            usageSession: session
        )

        let refresh = Task { await model.refreshAll(surface: "removal-race-test") }
        let appRequestPaused = await waitForStubRequests(1)
        XCTAssertTrue(appRequestPaused, "The provider request never reached the pause point")

        try await model.removeAccount(account)
        StubURLProtocol.resumePausedResponses()
        _ = await refresh.value
        await waitForLedgerRemoval(accountKey: account.key, directory: directory)

        XCTAssertEqual(
            StubURLProtocol.requestCount,
            2,
            "the stale request should reach token rotation, then fail its guarded Keychain write"
        )
        XCTAssertNil(try vault.load(accountKey: account.key), "a rotated credential must not return")
        XCTAssertNil(try SnapshotStore(directory: directory).current(accountKey: account.key))
        XCTAssertTrue(try UsageHistoryStore(directory: directory).load(accountKey: account.key).isEmpty)
        XCTAssertTrue(try PendingEventStore(directory: directory).load(accountKey: account.key).isEmpty)
        XCTAssertNil(try FileLedgerStore(directory: directory).load()[account.key])
        XCTAssertTrue(try AccountIndex.load(from: directory.appendingPathComponent("account-index.json")).isEmpty)
    }

    func testSecondLifecycleStoreBlocksWidgetStyleLateWritesAfterRemoval() async throws {
        let directory = try makeTemporaryDirectory()
        let credentials = Credentials(
            providerId: "openrouter",
            accessToken: "test-key",
            source: "manual"
        )
        let account = AccountRef(
            key: AppModel.accountKey(for: credentials),
            providerId: credentials.providerId,
            label: "Work",
            plan: nil
        )
        let writerLifecycle = AccountLifecycleStore(directory: directory)
        let removerLifecycle = AccountLifecycleStore(directory: directory)
        let generation = try writerLifecycle.beginNewLifecycle(accountKey: account.key)
        let vault = InMemoryCredentialsStore()
        try vault.save(credentials, accountKey: account.key)
        let snapshots = SnapshotStore(directory: directory)
        let history = UsageHistoryStore(directory: directory)
        let pending = PendingEventStore(directory: directory)
        let scheduler = FetchScheduler(
            store: FileLedgerStore(directory: directory),
            jitter: { _ in 0 }
        )

        StubURLProtocol.reset()
        StubURLProtocol.respond(statusCode: 200, body: Data(Self.openRouterSuccessBody.utf8))
        StubURLProtocol.pauseResponses()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let refresh = Task {
            await UsageService.refresh(
                account: account,
                credentials: credentials,
                scheduler: scheduler,
                snapshots: snapshots,
                vault: vault,
                surface: "widget-race-test",
                session: session,
                pendingEvents: pending,
                history: history,
                lifecycle: writerLifecycle,
                generation: generation
            )
        }
        let widgetRequestPaused = await waitForStubRequests(1)
        XCTAssertTrue(widgetRequestPaused, "The widget-style request never reached the pause point")

        try removerLifecycle.tombstone(accountKey: account.key)
        try vault.delete(accountKey: account.key)
        try snapshots.delete(accountKey: account.key)
        try history.delete(accountKey: account.key)
        try pending.delete(accountKey: account.key)
        let ledgerCleared = await scheduler.clear(accountKey: account.key)
        XCTAssertTrue(ledgerCleared)

        StubURLProtocol.resumePausedResponses()
        let result = await refresh.value

        XCTAssertNil(result.snapshot)
        XCTAssertNil(try vault.load(accountKey: account.key))
        XCTAssertNil(try snapshots.current(accountKey: account.key))
        XCTAssertTrue(try history.load(accountKey: account.key).isEmpty)
        XCTAssertTrue(try pending.load(accountKey: account.key).isEmpty)
        XCTAssertNil(try FileLedgerStore(directory: directory).load()[account.key])
        XCTAssertFalse(try writerLifecycle.isCurrent(generation, accountKey: account.key))
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

    private func seedPendingSnapshot(
        account: AccountRef,
        directory: URL,
        fetchedAt: Date,
        resetAt: Date?,
        windows: [(String, Double)]
    ) throws {
        try AccountIndex.save(
            [account],
            to: directory.appendingPathComponent("account-index.json")
        )
        let snapshot = ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: fetchedAt,
            status: .ok,
            windows: windows.map { id, utilization in
                UsageWindow(
                    id: id,
                    utilization: utilization,
                    resetsAt: resetAt,
                    windowSeconds: 18_000,
                    secondary: false
                )
            }
        )
        try SnapshotStore(directory: directory).save(
            snapshot,
            accountKey: account.key
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

    private func waitForStubRequests(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if StubURLProtocol.requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForRelinkRaceRequest(_ gate: RelinkRaceGate) async -> Bool {
        for _ in 0..<200 {
            if gate.requestCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForHistoryCount(
        _ count: Int,
        account: AccountRef,
        model: AppModel
    ) async -> Bool {
        for _ in 0..<200 {
            if model.history(for: account).count == count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForLedgerRemoval(accountKey: String, directory: URL) async {
        for _ in 0..<200 {
            if (try? FileLedgerStore(directory: directory).load()[accountKey]) == nil {
                return
            }
            await Task.yield()
        }
    }

    private func waitForLedgerClearStart(_ store: PausingClearLedgerStore) async -> Bool {
        for _ in 0..<200 {
            if store.clearHasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForNotificationDeliveryStart(
        _ notifications: PausingNotificationManager
    ) async -> Bool {
        for _ in 0..<200 {
            if await notifications.deliveryHasStarted() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForRemovalNotificationStart(
        _ notifications: PausingRemovalNotificationManager
    ) async -> Bool {
        for _ in 0..<200 {
            if await notifications.removalHasStarted() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForFullRecoveryResetStart(_ model: AppModel) async -> Bool {
        for _ in 0..<200 {
            if model.isResettingAllLocalData { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func snapshot(
        for account: AccountRef,
        utilization: Double
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: account.providerId,
            accountKey: account.key,
            accountLabel: account.label,
            planLabel: account.plan,
            fetchedAt: Date(),
            status: .ok,
            windows: [
                UsageWindow(
                    id: "session",
                    utilization: utilization,
                    resetsAt: Date().addingTimeInterval(3_600),
                    windowSeconds: 18_000,
                    secondary: false
                ),
            ]
        )
    }

    private static let openRouterSuccessBody = #"""
    {
      "data": {
        "label": "vigil-test",
        "usage": 12.5,
        "usage_daily": 0.5,
        "usage_weekly": 4.25,
        "usage_monthly": 9.75,
        "byok_usage": 3.5,
        "byok_usage_daily": 0.25,
        "byok_usage_weekly": 1.5,
        "byok_usage_monthly": 2.75,
        "limit": 50,
        "limit_reset": "monthly",
        "is_free_tier": false,
        "limit_remaining": 37.5,
        "rate_limit": { "requests": 200, "interval": "10s" }
      }
    }
    """#

    private static let codexLiveSpendControlBody = #"""
    {
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 23.5,
          "reset_at": 1785268800,
          "limit_window_seconds": 18000
        },
        "secondary_window": null
      },
      "spend_control": {
        "reached": false,
        "individual_limit": null
      },
      "code_review_rate_limit": null
    }
    """#
}

private actor RecordingNotificationManager: NotificationManaging {
    private var authorizationRequests = 0
    private var delivered: [ThresholdEvent] = []
    private var removedAccounts: [String] = []
    private var exactRemovedIdentifiers: [String] = []
    private var removedAllVigil = false
    private let failedEvents: [ThresholdEvent]

    init(failedEvents: [ThresholdEvent] = []) {
        self.failedEvents = failedEvents
    }

    func requestAuthorizationIfNeeded() async {
        authorizationRequests += 1
    }

    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] {
        delivered.append(contentsOf: events)
        return events.filter { failedEvents.contains($0) }
    }

    func removeNotifications(accountKey: String) async {
        removedAccounts.append(accountKey)
    }

    func removeNotifications(identifiers: [String]) async {
        exactRemovedIdentifiers.append(contentsOf: identifiers)
    }

    func removeAllVigilNotifications() async {
        removedAllVigil = true
    }

    func authorizationRequestCount() -> Int {
        authorizationRequests
    }

    func deliveredEvents() -> [ThresholdEvent] {
        delivered
    }

    func removedAccountKeys() -> [String] {
        removedAccounts
    }

    func didRemoveAllVigilNotifications() -> Bool {
        removedAllVigil
    }
}

private actor PausingNotificationManager: NotificationManaging {
    private var deliveryStarted = false
    private var deliveryContinuation: CheckedContinuation<Void, Never>?
    private var deliveryResumed = false
    private var removedAccounts: [String] = []
    private var exactRemovedIdentifiers: [String] = []
    private var removeAllCount = 0
    private var hasScheduledNotification = false

    func requestAuthorizationIfNeeded() async {}

    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] {
        let isFirstDelivery = !deliveryStarted
        deliveryStarted = true
        if isFirstDelivery, !deliveryResumed {
            await withCheckedContinuation { continuation in
                deliveryContinuation = continuation
            }
        }
        hasScheduledNotification = true
        return []
    }

    func removeNotifications(accountKey: String) async {
        removedAccounts.append(accountKey)
        hasScheduledNotification = false
    }

    func removeNotifications(identifiers: [String]) async {
        exactRemovedIdentifiers.append(contentsOf: identifiers)
        if !identifiers.isEmpty {
            hasScheduledNotification = false
        }
    }

    func removeAllVigilNotifications() async {
        removeAllCount += 1
        hasScheduledNotification = false
    }

    func deliveryHasStarted() -> Bool {
        deliveryStarted
    }

    func resumeDelivery() {
        deliveryResumed = true
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }

    func removedAccountKeys() -> [String] {
        removedAccounts
    }

    func removedIdentifiers() -> [String] {
        exactRemovedIdentifiers
    }

    func removeAllVigilCount() -> Int {
        removeAllCount
    }

    func hasScheduledVigilNotification() -> Bool {
        hasScheduledNotification
    }
}

private actor PausingRemovalNotificationManager: NotificationManaging {
    private var removalStarted = false
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var removalResumed = false

    func requestAuthorizationIfNeeded() async {}

    func deliver(
        events: [ThresholdEvent],
        account: AccountRef,
        deliveryScope: String
    ) async -> [ThresholdEvent] {
        []
    }

    func removeNotifications(accountKey: String) async {
        removalStarted = true
        guard !removalResumed else { return }
        await withCheckedContinuation { continuation in
            removalContinuation = continuation
        }
    }

    func removeNotifications(identifiers: [String]) async {}

    func removalHasStarted() -> Bool {
        removalStarted
    }

    func resumeRemoval() {
        removalResumed = true
        removalContinuation?.resume()
        removalContinuation = nil
    }
}

private enum TestStoreError: Error {
    case deleteFailed
    case saveFailed
    case loadFailed
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

private final class UnreadableCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private let accountKey: String
    private var exists = true

    init(accountKey: String) {
        self.accountKey = accountKey
    }

    func save(_ credentials: Credentials, accountKey: String) throws {
        lock.withLock { exists = true }
    }

    func load(accountKey: String) throws -> Credentials? {
        guard lock.withLock({ exists && accountKey == self.accountKey }) else {
            return nil
        }
        throw TestStoreError.loadFailed
    }

    func delete(accountKey: String) throws {
        guard accountKey == self.accountKey else { return }
        lock.withLock { exists = false }
    }

    func allKeys() throws -> [String] {
        lock.withLock { exists ? [accountKey] : [] }
    }
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class PausingClearLedgerStore: LedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private let resumeSemaphore = DispatchSemaphore(value: 0)
    private let accountKey: String
    private var storage: [String: LedgerEntry]
    private var clearStarted = false
    private var didResume = false

    init(accountKey: String, initial: [String: LedgerEntry]) {
        self.accountKey = accountKey
        self.storage = initial
    }

    var clearHasStarted: Bool {
        lock.withLock { clearStarted }
    }

    func load() throws -> [String: LedgerEntry] {
        lock.withLock { storage }
    }

    func update(_ mutation: (inout [String: LedgerEntry]) -> Void) throws {
        lock.lock()
        var candidate = storage
        mutation(&candidate)
        let shouldPause = !clearStarted
            && storage[accountKey] != nil
            && candidate[accountKey] == nil
        if shouldPause { clearStarted = true }
        lock.unlock()

        if shouldPause { resumeSemaphore.wait() }

        lock.withLock { storage = candidate }
    }

    func resumeClear() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didResume else { return false }
            didResume = true
            return true
        }
        if shouldSignal { resumeSemaphore.signal() }
    }
}

private struct UpdateFailingLedgerStore: LedgerStore {
    let initial: [String: LedgerEntry]

    func load() throws -> [String: LedgerEntry] {
        initial
    }

    func update(_ mutation: (inout [String: LedgerEntry]) -> Void) throws {
        throw TestStoreError.saveFailed
    }
}

private final class RelinkRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RelinkRaceURLProtocol] = []
    private var paused = true
    private var requests = 0

    let statusCode: Int
    let body: Data

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func start(_ protocolInstance: RelinkRaceURLProtocol) {
        let shouldDeliver = lock.withLock { () -> Bool in
            requests += 1
            if paused {
                pending.append(protocolInstance)
                return false
            }
            return true
        }
        if shouldDeliver { protocolInstance.deliver(statusCode: statusCode, body: body) }
    }

    func stop(_ protocolInstance: RelinkRaceURLProtocol) {
        lock.withLock {
            pending.removeAll { $0 === protocolInstance }
        }
    }

    func resume() {
        let protocols = lock.withLock { () -> [RelinkRaceURLProtocol] in
            paused = false
            let protocols = pending
            pending = []
            return protocols
        }
        protocols.forEach { $0.deliver(statusCode: statusCode, body: body) }
    }
}

private final class RelinkRaceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let identifierHeader = "X-Vigil-Relink-Race"
    private static let lock = NSLock()
    private static var gates: [String: RelinkRaceGate] = [:]

    static func makeSession(
        statusCode: Int,
        body: Data
    ) -> (session: URLSession, identifier: String, gate: RelinkRaceGate) {
        let identifier = UUID().uuidString
        let gate = RelinkRaceGate(statusCode: statusCode, body: body)
        lock.withLock { gates[identifier] = gate }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelinkRaceURLProtocol.self]
        configuration.httpAdditionalHeaders = [identifierHeader: identifier]
        return (URLSession(configuration: configuration), identifier, gate)
    }

    static func unregister(_ identifier: String) {
        lock.withLock { gates[identifier] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let identifier = request.value(forHTTPHeaderField: Self.identifierHeader),
              let gate = Self.lock.withLock({ Self.gates[identifier] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        gate.start(self)
    }

    override func stopLoading() {
        guard let identifier = request.value(forHTTPHeaderField: Self.identifierHeader),
              let gate = Self.lock.withLock({ Self.gates[identifier] })
        else { return }
        gate.stop(self)
    }

    fileprivate func deliver(statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    private static var transportFails = false
    private static var configuredStatusCode: Int?
    private static var configuredBody: Data?
    private static var responsesPaused = false
    private static var pausedProtocols: [StubURLProtocol] = []

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
            configuredStatusCode = nil
            configuredBody = nil
            responsesPaused = false
            pausedProtocols = []
        }
    }

    static func respond(statusCode: Int, body: Data) {
        lock.withLock {
            configuredStatusCode = statusCode
            configuredBody = body
        }
    }

    static func pauseResponses() {
        lock.withLock { responsesPaused = true }
    }

    static func resumePausedResponses() {
        let protocols = lock.withLock { () -> [StubURLProtocol] in
            responsesPaused = false
            let protocols = pausedProtocols
            pausedProtocols = []
            return protocols
        }
        protocols.forEach { $0.deliverResponse() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let shouldPause = Self.lock.withLock { () -> Bool in
            Self.requests += 1
            if Self.responsesPaused {
                Self.pausedProtocols.append(self)
                return true
            }
            return false
        }
        if shouldPause { return }
        deliverResponse()
    }

    private func deliverResponse() {
        if Self.failsTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let configured = Self.lock.withLock {
            Self.configuredStatusCode.map { ($0, Self.configuredBody ?? Data()) }
        }
        if let (status, body) = configured {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
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

    override func stopLoading() {
        Self.lock.withLock {
            Self.pausedProtocols.removeAll { $0 === self }
        }
    }
}
