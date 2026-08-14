import Darwin
import Foundation

/// A persistence failure with enough context for callers to distinguish
/// missing data from corruption and storage failures.
public enum StorePersistenceError: Error, Equatable, Sendable {
    case directoryCreationFailed(path: String, reason: String)
    case lockFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case corruptData(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case deleteFailed(path: String, reason: String)
}

extension StorePersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .directoryCreationFailed(path, reason):
            return "Could not prepare the persistence directory at \(path): \(reason)"
        case let .lockFailed(path, reason):
            return "Could not lock the persistence file at \(path): \(reason)"
        case let .readFailed(path, reason):
            return "Could not read the persistence file at \(path): \(reason)"
        case let .corruptData(path, reason):
            return "The persistence file at \(path) is corrupt: \(reason)"
        case let .writeFailed(path, reason):
            return "Could not write the persistence file at \(path): \(reason)"
        case let .deleteFailed(path, reason):
            return "Could not delete the persistence file at \(path): \(reason)"
        }
    }
}

/// POSIX-backed storage primitives shared by the snapshot and pending-event
/// stores. Locks are advisory and cross-process. Writes use a same-directory
/// temporary file, fsync, and atomic rename so a crash cannot expose partial
/// JSON.
enum PersistenceFileIO {
    static let maximumTrustedFileBytes = 1_048_576

    static func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false

        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try validateDirectory(directory, isDirectory: isDirectory)
            try tightenDirectoryPermissions(directory)
            return
        }

        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Another process may have won the directory-creation race.
            var nowDirectory: ObjCBool = false
            if manager.fileExists(atPath: directory.path, isDirectory: &nowDirectory),
               nowDirectory.boolValue {
                try validateDirectory(directory, isDirectory: nowDirectory)
            } else {
                throw StorePersistenceError.directoryCreationFailed(
                    path: directory.path,
                    reason: error.localizedDescription
                )
            }
        }

        try tightenDirectoryPermissions(directory)
    }

    private static func validateDirectory(_ directory: URL, isDirectory: ObjCBool) throws {
        guard isDirectory.boolValue else {
            throw StorePersistenceError.directoryCreationFailed(
                path: directory.path,
                reason: "A non-directory item already exists at this path."
            )
        }

        do {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw StorePersistenceError.directoryCreationFailed(
                    path: directory.path,
                    reason: "Symbolic-link directories are not accepted."
                )
            }
        } catch let error as StorePersistenceError {
            throw error
        } catch {
            throw StorePersistenceError.directoryCreationFailed(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func tightenDirectoryPermissions(_ directory: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw StorePersistenceError.directoryCreationFailed(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    static func withExclusiveLock<T>(
        at lockURL: URL,
        _ body: () throws -> T
    ) throws -> T {
        try ensureDirectory(lockURL.deletingLastPathComponent())

        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw StorePersistenceError.lockFailed(
                path: lockURL.path,
                reason: posixReason()
            )
        }

        var isLocked = false
        defer {
            if isLocked {
                _ = flock(descriptor, LOCK_UN)
            }
            _ = Darwin.close(descriptor)
        }

        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw StorePersistenceError.lockFailed(
                path: lockURL.path,
                reason: posixReason()
            )
        }

        do {
            try applyFileProtection(to: lockURL)
        } catch {
            throw StorePersistenceError.lockFailed(
                path: lockURL.path,
                reason: error.localizedDescription
            )
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw StorePersistenceError.lockFailed(
                    path: lockURL.path,
                    reason: posixReason()
                )
            }
        }
        isLocked = true
        return try body()
    }

    static func readIfPresent(at url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StorePersistenceError.readFailed(path: url.path, reason: posixReason())
        }
        defer { _ = Darwin.close(descriptor) }

        // Tighten legacy files created before owner-only permissions and file
        // protection were enforced.
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw StorePersistenceError.readFailed(path: url.path, reason: posixReason())
        }
        do {
            try applyFileProtection(to: url)
        } catch {
            throw StorePersistenceError.readFailed(path: url.path, reason: error.localizedDescription)
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw StorePersistenceError.readFailed(path: url.path, reason: posixReason())
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw StorePersistenceError.readFailed(
                path: url.path,
                reason: "The path does not contain a regular file."
            )
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= maximumTrustedFileBytes
        else {
            throw StorePersistenceError.corruptData(
                path: url.path,
                reason: "The file exceeds the trusted-container size ceiling."
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                data.append(buffer, count: count)
                if data.count > maximumTrustedFileBytes {
                    throw StorePersistenceError.corruptData(
                        path: url.path,
                        reason: "The file exceeds the trusted-container size ceiling."
                    )
                }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw StorePersistenceError.readFailed(path: url.path, reason: posixReason())
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
        }

        var descriptorOpen = true
        var renamed = false
        defer {
            if descriptorOpen {
                _ = Darwin.close(descriptor)
            }
            if !renamed {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw StorePersistenceError.writeFailed(
                            path: url.path,
                            reason: posixReason()
                        )
                    }
                }
            }

            guard Darwin.fsync(descriptor) == 0 else {
                throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorOpen = false
                throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
            }
            descriptorOpen = false

            try applyFileProtection(to: temporaryURL)

            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
            }
            renamed = true

            guard Darwin.chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
            }
            try syncDirectory(url.deletingLastPathComponent(), operationPath: url.path)
        } catch let error as StorePersistenceError {
            throw error
        } catch {
            throw StorePersistenceError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    static func removeIfPresent(at url: URL) throws {
        if Darwin.unlink(url.path) == 0 {
            do {
                try syncDirectory(url.deletingLastPathComponent(), operationPath: url.path)
            } catch let StorePersistenceError.writeFailed(_, reason) {
                throw StorePersistenceError.deleteFailed(path: url.path, reason: reason)
            }
            return
        }
        if errno == ENOENT { return }
        throw StorePersistenceError.deleteFailed(path: url.path, reason: posixReason())
    }

    /// Tightens a SQLite-created file after it appears. SQLite owns creation
    /// of WAL and shared-memory sidecars, so stores cannot use the atomic JSON
    /// writer for them. The containing directory is already owner-only; this
    /// closes the remaining permissions and iOS data-protection gap.
    static func secureRegularFileIfPresent(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw StorePersistenceError.writeFailed(
                path: url.path,
                reason: "The path does not contain a regular file."
            )
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw StorePersistenceError.writeFailed(path: url.path, reason: posixReason())
        }
        do {
            try applyFileProtection(to: url)
        } catch {
            throw StorePersistenceError.writeFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func syncDirectory(_ directory: URL, operationPath: String) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw StorePersistenceError.writeFailed(path: operationPath, reason: posixReason())
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw StorePersistenceError.writeFailed(path: operationPath, reason: posixReason())
        }
    }

    private static func applyFileProtection(to url: URL) throws {
#if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    private static func posixReason() -> String {
        String(cString: strerror(errno))
    }
}

/// Current + previous snapshot per account as atomic JSON files in the App
/// Group container. `previous` exists solely so ThresholdEngine can detect
/// crossings; widgets read `current` without any network.
public struct SnapshotStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ accountKey: String, _ kind: String) -> URL {
        // Preserve the v1 filename mapping for backward compatibility.
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("snapshot-\(safe)-\(kind).json")
    }

    private func lockURL(_ accountKey: String) -> URL {
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("snapshot-\(safe).lock")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Rotates current -> previous, then writes the new current atomically.
    /// Corrupt current data is preserved and reported instead of overwritten.
    public func save(_ snapshot: ProviderSnapshot, accountKey: String) throws {
        let currentURL = url(accountKey, "current")
        let previousURL = url(accountKey, "previous")
        guard snapshot.accountKey == accountKey else {
            throw StorePersistenceError.writeFailed(
                path: currentURL.path,
                reason: "The snapshot account key does not match its storage key."
            )
        }
        // Encoding is pure; do it before taking the cross-process lock so the
        // hold window (0xdead10cc exposure) covers only the file rotation.
        // The existing-current decode stays inside the lock on purpose: it
        // gates the corrupt-current-is-preserved contract and must see the
        // same bytes it rotates.
        let data: Data
        do {
            data = try Self.encoder().encode(snapshot)
        } catch {
            throw StorePersistenceError.writeFailed(
                path: currentURL.path,
                reason: error.localizedDescription
            )
        }
        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            if let existing = try PersistenceFileIO.readIfPresent(at: currentURL) {
                do {
                    let decoded = try Self.decoder().decode(ProviderSnapshot.self, from: existing)
                    guard decoded.accountKey == accountKey else {
                        throw StorePersistenceError.corruptData(
                            path: currentURL.path,
                            reason: "The stored snapshot belongs to a different account key."
                        )
                    }
                } catch let error as StorePersistenceError {
                    throw error
                } catch {
                    throw StorePersistenceError.corruptData(
                        path: currentURL.path,
                        reason: error.localizedDescription
                    )
                }
                try PersistenceFileIO.writeAtomically(existing, to: previousURL)
            }

            try PersistenceFileIO.writeAtomically(data, to: currentURL)
        }
    }

    public func current(accountKey: String) throws -> ProviderSnapshot? {
        try read(accountKey: accountKey, kind: "current")
    }

    public func previous(accountKey: String) throws -> ProviderSnapshot? {
        try read(accountKey: accountKey, kind: "previous")
    }

    public func delete(accountKey: String) throws {
        try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            try PersistenceFileIO.removeIfPresent(at: url(accountKey, "current"))
            try PersistenceFileIO.removeIfPresent(at: url(accountKey, "previous"))
        }
    }

    /// Deletes both payloads and the account-key-derived advisory lock after
    /// the caller has tombstoned the account across every process. Do not use
    /// this for an active account because unlinking a live advisory lock can
    /// split future callers across two lock inodes.
    public func deleteRetiredAccount(accountKey: String) throws {
        try delete(accountKey: accountKey)
        try PersistenceFileIO.removeIfPresent(at: lockURL(accountKey))
    }

    private func read(accountKey: String, kind: String) throws -> ProviderSnapshot? {
        let fileURL = url(accountKey, kind)
        // Hold the cross-process lock only for the consistent byte copy.
        // Decoding runs on the private copy after release: a suspension while
        // any App Group lock is held kills the process (0xdead10cc), so the
        // hold window must not include JSON decoding.
        let data = try PersistenceFileIO.withExclusiveLock(at: lockURL(accountKey)) {
            try PersistenceFileIO.readIfPresent(at: fileURL)
        }
        guard let data else { return nil }
        do {
            let decoded = try Self.decoder().decode(ProviderSnapshot.self, from: data)
            guard decoded.accountKey == accountKey else {
                throw StorePersistenceError.corruptData(
                    path: fileURL.path,
                    reason: "The stored snapshot belongs to a different account key."
                )
            }
            return decoded
        } catch let error as StorePersistenceError {
            throw error
        } catch {
            throw StorePersistenceError.corruptData(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }
}
