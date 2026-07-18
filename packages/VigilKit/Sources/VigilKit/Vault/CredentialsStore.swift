import Foundation

public protocol CredentialsStore: Sendable {
    func save(_ credentials: Credentials, accountKey: String) throws
    func load(accountKey: String) throws -> Credentials?
    func delete(accountKey: String) throws
    func allKeys() throws -> [String]
}

/// Test/preview double; the app uses KeychainCredentialsStore.
public final class InMemoryCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Credentials] = [:]

    public init() {}

    public func save(_ credentials: Credentials, accountKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountKey] = credentials
    }

    public func load(accountKey: String) throws -> Credentials? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountKey]
    }

    public func delete(accountKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountKey)
    }

    public func allKeys() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.keys).sorted()
    }
}
