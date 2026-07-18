import Foundation

/// Current + previous snapshot per account as atomic JSON files in the App
/// Group container. `previous` exists solely so ThresholdEngine can detect
/// crossings; widgets read `current` without any network.
public struct SnapshotStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ accountKey: String, _ kind: String) -> URL {
        // Account keys may contain characters unfit for filenames.
        let safe = accountKey.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("snapshot-\(safe)-\(kind).json")
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
    public func save(_ snapshot: ProviderSnapshot, accountKey: String) throws {
        let currentURL = url(accountKey, "current")
        let previousURL = url(accountKey, "previous")
        if let existing = try? Data(contentsOf: currentURL) {
            try? existing.write(to: previousURL, options: .atomic)
        }
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: currentURL, options: .atomic)
    }

    public func current(accountKey: String) -> ProviderSnapshot? {
        guard let data = try? Data(contentsOf: url(accountKey, "current")) else { return nil }
        return try? Self.decoder().decode(ProviderSnapshot.self, from: data)
    }

    public func previous(accountKey: String) -> ProviderSnapshot? {
        guard let data = try? Data(contentsOf: url(accountKey, "previous")) else { return nil }
        return try? Self.decoder().decode(ProviderSnapshot.self, from: data)
    }

    public func delete(accountKey: String) {
        try? FileManager.default.removeItem(at: url(accountKey, "current"))
        try? FileManager.default.removeItem(at: url(accountKey, "previous"))
    }
}
