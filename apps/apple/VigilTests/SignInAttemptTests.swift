import XCTest
@testable import Vigil

/// SignInAttempt owns the lifecycle of one restartable, cancellable sign-in
/// attempt. It exists because the SwiftUI sweep found an unstructured retry
/// Task in CodexSignInView that survived view dismissal: a cancelled
/// sign-in could still link an account up to 15 minutes later.
@MainActor
final class SignInAttemptTests: XCTestCase {
    func testCancelPreventsALateCompletionFromPublishing() async throws {
        let attempt = SignInAttempt()
        var linked = false
        let operationStarted = expectation(description: "operation started")
        let operationFinished = expectation(description: "operation finished")

        attempt.start { isCurrent in
            operationStarted.fulfill()
            // Simulate the device-code poll: a wait that ends — like a
            // network callback — whether or not anyone still cares.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if isCurrent(), !Task.isCancelled {
                linked = true
            }
            operationFinished.fulfill()
        }

        await fulfillment(of: [operationStarted], timeout: 2)
        XCTAssertTrue(attempt.isRunning)
        attempt.cancel()
        XCTAssertFalse(attempt.isRunning)
        await fulfillment(of: [operationFinished], timeout: 2)
        XCTAssertFalse(linked, "A cancelled sign-in must never link an account")
    }

    func testStartWhileRunningCancelsThePreviousAttempt() async throws {
        let attempt = SignInAttempt()
        var firstSawCancellation = false
        let firstFinished = expectation(description: "first attempt finished")

        attempt.start { _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            firstSawCancellation = true
            firstFinished.fulfill()
        }
        attempt.start { _ in }

        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertTrue(firstSawCancellation, "Retry must cancel the previous attempt")
        attempt.cancel()
    }

    func testASupersededAttemptsCleanupDoesNotClearTheNewerAttempt() async throws {
        let attempt = SignInAttempt()
        let firstFinished = expectation(description: "first attempt unwound")
        let secondStarted = expectation(description: "second attempt started")
        var secondIsCurrent: (@MainActor () -> Bool)?

        attempt.start { _ in
            // Unwinds shortly after being cancelled — its cleanup then
            // races the second attempt, exactly like ClaudeSignInView's
            // defer cleared a newer attempt's isExchanging/exchangeTask.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            firstFinished.fulfill()
        }
        attempt.start { isCurrent in
            secondIsCurrent = isCurrent
            secondStarted.fulfill()
            // Stay in flight while the first attempt's cleanup unwinds.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        await fulfillment(of: [firstFinished, secondStarted], timeout: 2)
        // Give the first attempt's post-operation cleanup time to run.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(
            attempt.isRunning,
            "The first attempt's cleanup cleared the second attempt's running state"
        )
        XCTAssertEqual(
            secondIsCurrent?(), true,
            "The second attempt must still be the active one"
        )
        attempt.cancel()
    }
}
