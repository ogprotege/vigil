import XCTest
@testable import Vigil

/// Regression coverage for the 0xdead10cc fix: every lock-holding history
/// critical section runs inside SuspensionGuard, whose contract is to execute
/// the body exactly once, return its value, and rethrow its error while a
/// background-task assertion is held (and always ended) around it.
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
