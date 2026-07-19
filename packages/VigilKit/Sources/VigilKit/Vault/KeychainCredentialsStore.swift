#if canImport(Security)
import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

/// Keychain-backed vault. Items are AfterFirstUnlockThisDeviceOnly: background
/// refresh can read them, iCloud Keychain never syncs them — each device links
/// via its own scan (docs/privacy.md). Pass the shared access group so the
/// widget extension can read tokens for its staleness fetches.
///
/// Note: Keychain requires an entitled host app, so this type is exercised on
/// device (mac-checklist M4), not in `swift test`.
public final class KeychainCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "app.vigil.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(accountKey: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // On macOS this opts into the iOS-style data-protection keychain —
            // without it, kSecAttrAccessible and access groups are inert there.
            // On iOS it is already the default.
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accountKey {
            query[kSecAttrAccount as String] = accountKey
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func save(_ credentials: Credentials, accountKey: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(credentials)
        } catch {
            throw KeychainError.encodingFailed
        }

        var attributes = baseQuery(accountKey: accountKey)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(accountKey: accountKey) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func load(accountKey: String) throws -> Credentials? {
        var query = baseQuery(accountKey: accountKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt item is different from a missing item. Propagate the
        // decoding error so callers do not silently treat undeletable secret
        // material as if no credentials existed.
        return try decoder.decode(Credentials.self, from: data)
    }

    public func delete(accountKey: String) throws {
        let status = SecItemDelete(baseQuery(accountKey: accountKey) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func allKeys() throws -> [String] {
        var query = baseQuery(accountKey: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
#endif
