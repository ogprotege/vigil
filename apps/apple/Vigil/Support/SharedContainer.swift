import Foundation
import OSLog
import VigilKit

/// Resolves the App Group container shared by the app and the widget
/// extension — the one place SnapshotStore + the polling ledger live so every
/// process draws from a single budget (docs/architecture.md).
enum SharedContainer {
    private static let log = Logger(subsystem: "app.vigil", category: "storage")
    static let appGroupID = "group.app.vigil.shared"
    static let refreshTaskID = "app.vigil.refresh"

    /// Falls back to Application Support when the app-group entitlement is
    /// unavailable (SwiftUI previews, unsigned local builds) so the app still
    /// functions — sharing just degrades to per-process.
    static var directory: URL {
        let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
        if groupContainer == nil {
            log.warning("App Group container unavailable; using Application Support fallback")
        }
        let base = groupContainer
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VigilShared", isDirectory: true)
        // Creating this early improves startup diagnostics. The stores also
        // validate and create their directories before each durable write.
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )
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

    /// Widget selection is deliberately stable. With no configuration, the
    /// first account is a sensible default. Once configured, a missing account
    /// returns nil instead of exposing a different account by silently falling
    /// back to the first one.
    static func selected(from refs: [AccountRef], accountKey: String?) -> AccountRef? {
        guard let accountKey else { return refs.first }
        return refs.first { $0.key == accountKey }
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
