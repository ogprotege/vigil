import Darwin
import CryptoKit
import Foundation
import os
import OSLog
import VigilKit

/// Resolves the App Group container shared by the app and the widget
/// extension — the one place SnapshotStore + the polling ledger live so every
/// process draws from a single budget (docs/architecture.md).
enum SharedContainer {
    private static let log = Logger(subsystem: "app.vigil", category: "storage")
    static let appGroupID = "group.app.vigil.shared"
    static let refreshTaskID = "app.vigil.refresh"

    private static let fallbackState = OSAllocatedUnfairLock(initialState: false)

    /// True when `directory` last resolved to the per-process Application
    /// Support fallback instead of the App Group container. In that state the
    /// app and widget processes each keep their own polling ledger, so the
    /// cross-process no-double-poll guarantee is degraded — the app surfaces
    /// this through the storage-error alert path at startup (AppModel), and
    /// the widget process logs it below.
    static var isUsingFallbackStorage: Bool {
        fallbackState.withLock { $0 }
    }

    /// Pure resolution, separated so the fallback decision is unit-testable.
    static func resolveDirectory(
        groupContainer: URL?,
        applicationSupport: URL
    ) -> (url: URL, usedFallback: Bool) {
        let base = groupContainer ?? applicationSupport
        return (
            base.appendingPathComponent("VigilShared", isDirectory: true),
            groupContainer == nil
        )
    }

    /// Falls back to Application Support when the app-group entitlement is
    /// unavailable (SwiftUI previews, unsigned local builds) so the app still
    /// functions — sharing just degrades to per-process. Never silently: the
    /// fallback is recorded in `isUsingFallbackStorage` for the app to surface.
    static var directory: URL {
        let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
        let resolved = resolveDirectory(
            groupContainer: groupContainer,
            applicationSupport: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
        )
        fallbackState.withLock { $0 = resolved.usedFallback }
        if resolved.usedFallback {
            log.warning("App Group container unavailable; using Application Support fallback — cross-process poll sharing is disabled")
        }
        let dir = resolved.url
        // Creating this early improves startup diagnostics. The stores also
        // validate and create their directories before each durable write.
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Foundation's attribute bridge reads every extended attribute,
            // and provenance metadata can block that read or a redundant
            // chmod. POSIX lstat reads only the mode, so already-secure
            // directories skip the risky no-op.
            var fileInfo = stat()
            if Darwin.lstat(dir.path, &fileInfo) != 0 {
                let code = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(code),
                    userInfo: [
                        NSFilePathErrorKey: dir.path,
                        NSLocalizedDescriptionKey: String(cString: strerror(code)),
                    ]
                )
            }
            let permissions = fileInfo.st_mode & mode_t(0o777)
            if permissions != mode_t(0o700),
               Darwin.chmod(dir.path, mode_t(0o700)) != 0 {
                let code = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(code),
                    userInfo: [
                        NSFilePathErrorKey: dir.path,
                        NSLocalizedDescriptionKey: String(cString: strerror(code)),
                    ]
                )
            }
        } catch {
            log.error(
                "Could not create shared container: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        return dir
    }

    static var accountIndexURL: URL {
        directory.appendingPathComponent("account-index.json")
    }

    /// Every storage root a prior build could have used on this installation.
    /// A fixed entitlement can move Vigil from its Application Support
    /// fallback into the App Group, but the old private root does not migrate
    /// or erase itself. Full recovery clears both when they are accessible.
    static func recoveryDirectories(current: URL) -> [URL] {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        var candidates = [
            current,
            resolveDirectory(
                groupContainer: nil,
                applicationSupport: applicationSupport
            ).url,
        ]
        if let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            candidates.append(
                resolveDirectory(
                    groupContainer: groupContainer,
                    applicationSupport: applicationSupport
                ).url
            )
        }

        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}

enum SharedKeychain {
    static let accessGroupInfoKey = "VigilKeychainAccessGroup"

    static func accessGroup(from infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?[accessGroupInfoKey] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var configuredAccessGroup: String? {
        accessGroup(from: Bundle.main.infoDictionary)
    }

    static func credentialsStore() -> any CredentialsStore {
        guard let configuredAccessGroup else {
            return KeychainCredentialsStore()
        }
        return FallbackCredentialsStore(
            primary: KeychainCredentialsStore(accessGroup: configuredAccessGroup),
            legacy: KeychainCredentialsStore()
        )
    }
}

/// Reads the explicit app/widget access group first. If an older build stored
/// an item in the app's default group, a successful read copies it into the
/// shared group. The legacy copy is retained until account removal. This is
/// deliberate: on systems where the default group already resolves to the
/// shared group, deleting a "legacy" item would delete the newly verified
/// primary item too.
final class FallbackCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let primary: any CredentialsStore
    private let legacy: any CredentialsStore

    init(primary: any CredentialsStore, legacy: any CredentialsStore) {
        self.primary = primary
        self.legacy = legacy
    }

    func save(_ credentials: Credentials, accountKey: String) throws {
        try primary.save(credentials, accountKey: accountKey)
    }

    func load(accountKey: String) throws -> Credentials? {
        if let current = try primary.load(accountKey: accountKey) {
            return current
        }
        guard let old = try legacy.load(accountKey: accountKey) else {
            return nil
        }
        try primary.save(old, accountKey: accountKey)
        guard try primary.load(accountKey: accountKey) == old else {
            throw KeychainMigrationError.verificationFailed
        }
        return old
    }

    func delete(accountKey: String) throws {
        var firstError: Error?
        do {
            try primary.delete(accountKey: accountKey)
        } catch {
            firstError = error
        }
        do {
            try legacy.delete(accountKey: accountKey)
        } catch {
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
    }

    func allKeys() throws -> [String] {
        let primaryKeys = try primary.allKeys()
        let legacyKeys = try legacy.allKeys()
        return Array(Set(primaryKeys + legacyKeys)).sorted()
    }
}

enum KeychainMigrationError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "A credential copied to the shared Keychain could not be verified."
    }
}

/// The app-maintained list of linked accounts, persisted in the shared
/// container so the widget process can enumerate accounts (SnapshotStore has
/// no listing API by design).
struct AccountRef: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let providerId: String
    var label: String?
    var plan: String?

    var id: String { key }

    var displayName: String {
        ProviderRegistry.spec(for: providerId)?.displayName ?? providerId
    }
}

enum OpaqueAccountIdentifier {
    private static let widgetPrefix = "v2."

    static func widgetID(for accountKey: String) -> String {
        let digest = SHA256.hash(data: Data(accountKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return widgetPrefix + digest
    }
}

enum AccountIndex {
    static func load(from url: URL = SharedContainer.accountIndexURL) throws -> [AccountRef] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let refs = try JSONDecoder().decode([AccountRef].self, from: data)
        try validateStorageKeys(refs)
        return refs
    }

    static func save(_ refs: [AccountRef], to url: URL = SharedContainer.accountIndexURL) throws {
        try validateStorageKeys(refs)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let data = try JSONEncoder().encode(refs)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Copies damaged bytes aside before recovery replaces the live index.
    /// The backup contains account references only, never credentials.
    @discardableResult
    static func preserveCorruptFile(at url: URL) throws -> URL {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        let data = try Data(contentsOf: url)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("account-index.corrupt-\(UUID().uuidString).json")
        try data.write(to: backup, options: [.atomic, .completeFileProtectionUnlessOpen])
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: backup.path)
        return backup
    }

    /// Damaged-index copies are useful only until a repaired live index has
    /// been reviewed. Remove them when the user explicitly removes an account
    /// so an old backup cannot retain that account's label or identifier.
    static func deleteCorruptBackups(
        in directory: URL = SharedContainer.directory
    ) throws {
        for backup in try corruptBackups(in: directory) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func hasCorruptBackups(
        in directory: URL = SharedContainer.directory
    ) throws -> Bool {
        try !corruptBackups(in: directory).isEmpty
    }

    private static func corruptBackups(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("account-index.corrupt-")
                && $0.pathExtension == "json"
        }.filter { backup in
            let values = try backup.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true
        }
    }

    /// Widget selection is deliberately stable. With no configuration, the
    /// first account is a sensible default. Once configured, a missing account
    /// returns nil instead of exposing a different account by silently falling
    /// back to the first one.
    static func selected(from refs: [AccountRef], accountKey: String?) -> AccountRef? {
        guard let accountKey else { return refs.first }
        return refs.first { $0.key == accountKey }
    }

    /// WidgetKit persists AppEntity identifiers outside Vigil's App Group.
    /// New configurations use an opaque digest so that persisted selection
    /// state never contains a provider account ID. Raw matching remains only
    /// as a migration bridge for widgets configured by older releases.
    static func selectedForWidget(
        from refs: [AccountRef],
        identifier: String?
    ) -> AccountRef? {
        guard let identifier else { return refs.first }
        return refs.first {
            OpaqueAccountIdentifier.widgetID(for: $0.key) == identifier
                || $0.key == identifier
        }
    }

    private static func validateStorageKeys(_ refs: [AccountRef]) throws {
        var byComponent: [String: String] = [:]
        for ref in refs {
            let component = storageComponent(ref.key)
            if let existing = byComponent[component] {
                throw AccountIndexError.collidingStorageKeys(existing, ref.key)
            }
            byComponent[component] = ref.key
        }
    }

    private static func storageComponent(_ accountKey: String) -> String {
        accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

enum AccountIndexError: LocalizedError {
    case collidingStorageKeys(String, String)

    var errorDescription: String? {
        switch self {
        case .collidingStorageKeys:
            return "Two account references resolve to the same local storage key."
        }
    }
}

// MARK: - Pre-lifecycle removal cleanup

/// Removes account-key residue that builds predating the lifecycle registry
/// could leave behind after deleting the account index and Keychain item.
/// Without a remaining identity surface, startup reconciliation cannot name
/// those departed accounts. Pruning against the reconciled keep-set prevents
/// an old polling floor from attaching to a later re-link and removes advisory
/// lock filenames that no live account can use.
enum OrphanedAccountStatePruner {
    struct Result: Equatable {
        let ledgerEntriesRemoved: Int
        let lockFilesRemoved: Int
    }

    static func prune(
        directory: URL,
        keepingAccountKeys accountKeys: Set<String>
    ) throws -> Result {
        var removedLedgerEntries = 0
        try FileLedgerStore(directory: directory).update { ledger in
            let originalCount = ledger.count
            ledger = ledger.filter { accountKeys.contains($0.key) }
            removedLedgerEntries = originalCount - ledger.count
        }

        let allowedLockNames = Set(accountKeys.flatMap { accountKey in
            let component = storageComponent(accountKey)
            return [
                "snapshot-\(component).lock",
                "pending-events-\(component).lock",
            ]
        })
        let manager = FileManager.default
        let contents = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removedLockFiles = 0
        for url in contents {
            let name = url.lastPathComponent
            let isAccountLock = (name.hasPrefix("snapshot-")
                || name.hasPrefix("pending-events-"))
                && name.hasSuffix(".lock")
            guard isAccountLock, !allowedLockNames.contains(name) else { continue }

            var metadata = stat()
            guard Darwin.lstat(url.path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw OrphanedAccountStateError.inspect(
                    path: url.path,
                    code: errno
                )
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw OrphanedAccountStateError.nonRegular(path: url.path)
            }
            guard Darwin.unlink(url.path) == 0 else {
                if errno == ENOENT { continue }
                throw OrphanedAccountStateError.remove(
                    path: url.path,
                    code: errno
                )
            }
            removedLockFiles += 1
        }
        return Result(
            ledgerEntriesRemoved: removedLedgerEntries,
            lockFilesRemoved: removedLockFiles
        )
    }

    private static func storageComponent(_ accountKey: String) -> String {
        accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

enum OrphanedAccountStateError: LocalizedError {
    case inspect(path: String, code: Int32)
    case nonRegular(path: String)
    case remove(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .inspect(let path, let code):
            return "Could not inspect retired account metadata at \(path) (errno \(code))."
        case .nonRegular(let path):
            return "Retired account metadata at \(path) is not a regular file."
        case .remove(let path, let code):
            return "Could not remove retired account metadata at \(path) (errno \(code))."
        }
    }
}

/// Broad file cleanup used only after the user confirms a full local-data
/// recovery. The lifecycle registry is force-tombstoned before this runs, so
/// no app or widget generation can recreate an account cache after deletion.
enum LocalDataRecoveryResetter {
    static func deleteAccountCachesAndIndex(in directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in contents where isResetTarget(url.lastPathComponent) {
            var metadata = stat()
            guard Darwin.lstat(url.path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw LocalDataRecoveryResetError.inspect(path: url.path, code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw LocalDataRecoveryResetError.nonRegular(path: url.path)
            }
            guard Darwin.unlink(url.path) == 0 else {
                if errno == ENOENT { continue }
                throw LocalDataRecoveryResetError.remove(path: url.path, code: errno)
            }
        }
    }

    private static func isResetTarget(_ name: String) -> Bool {
        if name == "account-index.json" { return true }
        if name.hasPrefix("account-index.corrupt-"), name.hasSuffix(".json") {
            return true
        }
        if name.hasPrefix("snapshot-"),
           name.hasSuffix(".json") || name.hasSuffix(".lock") {
            return true
        }
        if name.hasPrefix("pending-events-"),
           name.hasSuffix(".json") || name.hasSuffix(".lock") {
            return true
        }
        return false
    }
}

enum LocalDataRecoveryResetError: LocalizedError {
    case inspect(path: String, code: Int32)
    case nonRegular(path: String)
    case remove(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .inspect(let path, let code):
            return "Could not inspect local Vigil data at \(path) (errno \(code))."
        case .nonRegular(let path):
            return "Local Vigil data at \(path) is not a regular file."
        case .remove(let path, let code):
            return "Could not remove local Vigil data at \(path) (errno \(code))."
        }
    }
}

// MARK: - Shared account lifecycle

/// A fetch captures this opaque generation before it reads credentials. Every
/// later write must present the same generation while holding the lifecycle
/// lock. Credentials are replaceable; this local generation is the authority
/// for whether an app or widget writer still belongs to the linked account.
struct AccountLifecycleGeneration: Codable, Equatable, Hashable, Sendable {
    fileprivate let value: UUID

    fileprivate init(value: UUID = UUID()) {
        self.value = value
    }

    /// Opaque namespace for side effects that outlive an async boundary. It
    /// prevents cleanup from an older lifecycle from deleting work accepted
    /// for a newly re-linked account with the same stable key.
    var notificationScope: String { value.uuidString.lowercased() }
}

enum AccountLifecycleError: LocalizedError, Equatable {
    case inactiveAccount
    case staleGeneration
    case corruptRegistry(String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .inactiveAccount:
            return "The account is no longer active."
        case .staleGeneration:
            return "This operation belongs to an older account lifecycle."
        case .corruptRegistry(let reason):
            return "The shared account lifecycle registry is damaged: \(reason)"
        case .persistence(let reason):
            return "The shared account lifecycle registry could not be updated: \(reason)"
        }
    }
}

enum AccountLifecycleStatus: Equatable, Sendable {
    case active
    case tombstoned
}

/// Cross-process lifecycle authority shared by the app and widget. The small
/// registry has one global advisory lock. A guarded persistence operation holds
/// that lock only for the duration of a local store mutation, so removal can:
///
/// 1. tombstone the generation;
/// 2. wait for any earlier guarded write to finish; and
/// 3. delete every account-scoped store knowing an old request cannot write
///    again after the tombstone.
struct AccountLifecycleStore: Sendable {
    private enum State: String, Codable {
        case active
        case tombstoned
    }

    private struct Entry: Codable {
        var generation: AccountLifecycleGeneration
        var state: State
    }

    private struct Registry: Codable {
        var version = 1
        var accounts: [String: Entry] = [:]
    }

    private let directory: URL
    private let fileURL: URL
    private let lockURL: URL

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("account-lifecycle.json")
        self.lockURL = directory.appendingPathComponent("account-lifecycle.lock")
    }

    /// Upgrade path for accounts linked before lifecycle generations existed.
    /// A tombstone is never reactivated merely because an old account-index
    /// read still contains the account.
    func registerIfMissing(accountKey: String) throws -> AccountLifecycleGeneration? {
        try withLock {
            var registry = try loadUnlocked()
            if let entry = registry.accounts[accountKey] {
                return entry.state == .active ? entry.generation : nil
            }
            let generation = AccountLifecycleGeneration()
            registry.accounts[accountKey] = Entry(generation: generation, state: .active)
            try saveUnlocked(registry)
            return generation
        }
    }

    /// Starts a new active identity generation for a newly linked account or
    /// reactivates an account whose removal failed before the index changed.
    @discardableResult
    func beginNewLifecycle(accountKey: String) throws -> AccountLifecycleGeneration {
        try withLock {
            var registry = try loadUnlocked()
            let generation = AccountLifecycleGeneration()
            registry.accounts[accountKey] = Entry(generation: generation, state: .active)
            try saveUnlocked(registry)
            return generation
        }
    }

    /// Rotates the generation and performs a credential/index replacement
    /// before another process can capture the new generation. This is the
    /// cross-process transaction boundary for targeted re-linking.
    @discardableResult
    func rotateActiveGeneration<T>(
        accountKey: String,
        performing body: (AccountLifecycleGeneration) throws -> T
    ) throws -> T {
        try withLock {
            var registry = try loadUnlocked()
            guard registry.accounts[accountKey]?.state == .active else {
                throw AccountLifecycleError.inactiveAccount
            }
            let generation = AccountLifecycleGeneration()
            registry.accounts[accountKey] = Entry(generation: generation, state: .active)
            try saveUnlocked(registry)
            return try body(generation)
        }
    }

    /// The first step of removal. The fresh tombstone generation makes every
    /// previously captured app and widget generation permanently stale.
    func tombstone(accountKey: String) throws {
        try withLock {
            var registry = try loadUnlocked()
            registry.accounts[accountKey] = Entry(
                generation: AccountLifecycleGeneration(),
                state: .tombstoned
            )
            try saveUnlocked(registry)
        }
    }

    /// Destructive recovery entry point for an unreadable registry. It does
    /// not decode or trust the prior bytes. Replacing them with tombstones
    /// while holding the global lifecycle lock invalidates every generation,
    /// including writers whose keys are absent from the recoverable index.
    func forceRecoveryTombstones(accountKeys: Set<String>) throws {
        try withLock {
            var registry = Registry()
            for accountKey in accountKeys {
                registry.accounts[accountKey] = Entry(
                    generation: AccountLifecycleGeneration(),
                    state: .tombstoned
                )
            }
            try saveUnlocked(registry)
        }
    }

    /// Completes a successful full reset. Refuse to erase lifecycle authority
    /// if any account was unexpectedly reactivated during recovery.
    func finishFullRecoveryReset() throws {
        try withLock {
            let registry = try loadUnlocked()
            guard registry.accounts.values.allSatisfy({ $0.state == .tombstoned }) else {
                throw AccountLifecycleError.persistence(
                    "An account became active while local-data recovery was running."
                )
            }
            try saveUnlocked(Registry())
        }
    }

    func captureActiveGeneration(accountKey: String) throws -> AccountLifecycleGeneration? {
        try withLock {
            guard let entry = try loadUnlocked().accounts[accountKey], entry.state == .active else {
                return nil
            }
            return entry.generation
        }
    }

    /// Snapshot used only for startup reconciliation. Returning every entry is
    /// important because a crash can leave a tombstone after both the account
    /// index and Keychain item have already disappeared.
    func statuses() throws -> [String: AccountLifecycleStatus] {
        try withLock {
            try loadUnlocked().accounts.mapValues { entry in
                entry.state == .active ? .active : .tombstoned
            }
        }
    }

    /// Removes completed lifecycle metadata without ever reactivating it.
    /// The expected-state check prevents startup cleanup from deleting a new
    /// lifecycle created by a prompt re-link under the same account key.
    @discardableResult
    func removeEntry(
        accountKey: String,
        ifStatus expectedStatus: AccountLifecycleStatus
    ) throws -> Bool {
        try withLock {
            var registry = try loadUnlocked()
            guard let entry = registry.accounts[accountKey] else { return false }
            let actualStatus: AccountLifecycleStatus = entry.state == .active
                ? .active
                : .tombstoned
            guard actualStatus == expectedStatus else { return false }
            registry.accounts[accountKey] = nil
            try saveUnlocked(registry)
            return true
        }
    }

    func isCurrent(_ generation: AccountLifecycleGeneration, accountKey: String) throws -> Bool {
        try withLock {
            guard let entry = try loadUnlocked().accounts[accountKey] else { return false }
            return entry.state == .active && entry.generation == generation
        }
    }

    /// Validates and performs one synchronous persistence mutation without
    /// releasing the cross-process lifecycle lock between those two actions.
    func withCurrentGeneration<T>(
        _ generation: AccountLifecycleGeneration,
        accountKey: String,
        _ body: () throws -> T
    ) throws -> T {
        try withLock {
            try validateUnlocked(generation, accountKey: accountKey)
            return try body()
        }
    }

    private func validateUnlocked(
        _ generation: AccountLifecycleGeneration,
        accountKey: String
    ) throws {
        guard let entry = try loadUnlocked().accounts[accountKey], entry.state == .active else {
            throw AccountLifecycleError.inactiveAccount
        }
        guard entry.generation == generation else {
            throw AccountLifecycleError.staleGeneration
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        return try body()
    }

    private func acquireLock() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw AccountLifecycleError.persistence(error.localizedDescription)
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw AccountLifecycleError.persistence(String(cString: strerror(errno)))
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = Darwin.close(descriptor)
            throw AccountLifecycleError.persistence(reason)
        }
        #if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: lockURL.path
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw AccountLifecycleError.persistence(error.localizedDescription)
        }
        #endif
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let reason = String(cString: strerror(errno))
                _ = Darwin.close(descriptor)
                throw AccountLifecycleError.persistence(reason)
            }
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    private func loadUnlocked() throws -> Registry {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Registry()
        }
        do {
            return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: fileURL))
        } catch {
            throw AccountLifecycleError.corruptRegistry(error.localizedDescription)
        }
    }

    private func saveUnlocked(_ registry: Registry) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(registry).write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
        } catch let error as AccountLifecycleError {
            throw error
        } catch {
            throw AccountLifecycleError.persistence(error.localizedDescription)
        }
    }
}

extension AccountLifecycleStore: SchedulerLifecycleGuard {
    typealias Generation = AccountLifecycleGeneration
}
