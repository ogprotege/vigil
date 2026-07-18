import Foundation
import XCTest
@testable import VigilKit

enum TestSupport {
    /// …/packages/VigilKit/Tests/VigilKitTests/TestSupport.swift -> repo root.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VigilKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // VigilKit
            .deletingLastPathComponent() // packages
            .deletingLastPathComponent() // repo root
    }

    static func protocolFile(_ relative: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("protocol").appendingPathComponent(relative))
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigilkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func snapshot(
        windows: [UsageWindow],
        status: SnapshotStatus = .ok,
        accountKey: String = "claude:test"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerId: "claude",
            accountKey: accountKey,
            accountLabel: "Claude (max)",
            planLabel: "max",
            fetchedAt: Date(timeIntervalSince1970: 1_784_408_400),
            status: status,
            windows: windows
        )
    }

    static func window(_ id: String, _ utilization: Double) -> UsageWindow {
        UsageWindow(
            id: id,
            utilization: utilization,
            resetsAt: Date(timeIntervalSince1970: 1_784_412_000),
            windowSeconds: 18_000,
            secondary: false
        )
    }
}

/// Injectable clock for the scheduler tests.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}
