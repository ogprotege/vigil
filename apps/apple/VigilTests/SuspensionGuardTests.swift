import XCTest
@testable import Vigil

/// Regression coverage for the 0xdead10cc fix: every lock-holding history
/// and lifecycle critical section runs inside SuspensionGuard, whose contract
/// is to execute the body exactly once, return its value, and rethrow its
/// error while a background-task assertion is held (and always ended) around
/// it in the app process.
final class SuspensionGuardTests: XCTestCase {
    private struct SampleError: Error {}

    func testSyncBodyRunsAndReturnsValue() {
        var ran = false
        let value = SuspensionGuard.withProtection(named: "test") { () -> Int in
            ran = true
            return 42
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(value, 42)
    }

    func testSyncBodyRethrows() {
        XCTAssertThrowsError(
            try SuspensionGuard.withProtection(named: "test") {
                throw SampleError()
            }
        ) { XCTAssertTrue($0 is SampleError) }
    }

    func testAsyncBodyRunsAndReturnsValue() async {
        var ran = false
        let value = await SuspensionGuard.withProtection(named: "test") { () async -> Int in
            ran = true
            return 42
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(value, 42)
    }

    func testAsyncBodyRethrows() async {
        await XCTAssertAsyncThrowsError(
            try await SuspensionGuard.withProtection(named: "test") { () async throws in
                throw SampleError()
            }
        )
    }

    /// The XCTest host is the app process (not a `.appex`), so assertions are
    /// available. Widget builds share SuspensionGuard but skip beginBackgroundTask.
    func testAppTestHostCanHoldBackgroundTaskAssertion() {
        XCTAssertTrue(
            SuspensionGuard.canHoldBackgroundTaskAssertion,
            "Unit tests run in the app host; if this is false, lifecycle/history guards are no-ops in CI"
        )
    }

    /// Nested guards must each run their body exactly once (HistoryAppend
    /// wrapping withCurrentGeneration wrapping AccountLifecycle withLock).
    func testNestedProtectionRunsInnerBodyOnce() throws {
        var outer = 0
        var inner = 0
        let value = SuspensionGuard.withProtection(named: "outer") {
            outer += 1
            return SuspensionGuard.withProtection(named: "inner") { () -> Int in
                inner += 1
                return 7
            }
        }
        XCTAssertEqual(outer, 1)
        XCTAssertEqual(inner, 1)
        XCTAssertEqual(value, 7)
    }

    /// AccountLifecycleStore.withLock is the choke point for every generation
    /// capture/mutation. Prove capture still works after the SuspensionGuard
    /// wrap (the build 23 crash stack was captureActiveGeneration under flock).
    func testLifecycleCaptureRunsUnderWithLockProtection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-lifecycle-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountLifecycleStore(directory: directory)
        let accountKey = "claude:test-lifecycle-guard"
        let generation = try store.beginNewLifecycle(accountKey: accountKey)
        let captured = try store.captureActiveGeneration(accountKey: accountKey)
        XCTAssertEqual(captured, generation)
        XCTAssertTrue(try store.isCurrent(generation, accountKey: accountKey))
    }

    /// Rotation holds the lifecycle flock across the body (Keychain + index in
    /// production). The body must still run exactly once under protection.
    func testLifecycleRotationBodyRunsOnceUnderLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vigil-lifecycle-rotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountLifecycleStore(directory: directory)
        let accountKey = "openai:test-rotate-guard"
        _ = try store.beginNewLifecycle(accountKey: accountKey)
        var bodyRuns = 0
        let rotated = try store.rotateActiveGeneration(accountKey: accountKey) { generation in
            bodyRuns += 1
            return generation
        }
        XCTAssertEqual(bodyRuns, 1)
        XCTAssertEqual(try store.captureActiveGeneration(accountKey: accountKey), rotated)
    }

    private func XCTAssertAsyncThrowsError(
        _ expression: @autoclosure () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error to be thrown", file: file, line: line)
        } catch {
            XCTAssertTrue(error is SampleError, file: file, line: line)
        }
    }
}
