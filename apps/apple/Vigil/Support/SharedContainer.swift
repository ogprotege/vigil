import Foundation
import VigilKit

/// Resolves the App Group container shared by the app and the widget
/// extension — the one place SnapshotStore + the polling ledger live so every
/// process draws from a single budget (docs/architecture.md).
enum SharedContainer {
    static let appGroupID = "group.app.vigil.shared"
    static let refreshTaskID = "app.vigil.refresh"

    /// Falls back to Application Support when the app-group entitlement is
    /// unavailable (SwiftUI previews, unsigned local builds) so the app still
    /// functions — sharing just degrades to per-process.
    static var directory: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VigilShared", isDirectory: true)
        // SnapshotStore/FileLedgerStore never create their directory.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var accountIndexURL: URL {
        directory.appendingPathComponent("account-index.json")
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
    static func load() -> [AccountRef] {
        guard let data = try? Data(contentsOf: SharedContainer.accountIndexURL) else { return [] }
        return (try? JSONDecoder().decode([AccountRef].self, from: data)) ?? []
    }

    static func save(_ refs: [AccountRef]) {
        guard let data = try? JSONEncoder().encode(refs) else { return }
        try? data.write(to: SharedContainer.accountIndexURL, options: .atomic)
    }
}
