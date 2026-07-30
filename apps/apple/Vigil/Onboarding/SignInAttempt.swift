import Foundation
import Observation

/// One restartable, cancellable sign-in attempt owned by a view. Exists
/// because the SwiftUI sweep found two failure modes in the guided sign-in
/// views: an unstructured retry Task that survived view dismissal (a
/// cancelled sign-in could still link an account minutes later), and the
/// cancel/retry race AddAccountView.run documents.
@MainActor
@Observable
final class SignInAttempt {
    @ObservationIgnored private var task: Task<Void, Never>?
    private var activeAttemptID: UUID?

    nonisolated init() {}

    var isRunning: Bool { activeAttemptID != nil }

    /// Cancels any in-flight attempt and starts a new one. Every completion
    /// path in `operation` must consult `isCurrent()` (alongside
    /// `Task.isCancelled`) before publishing results.
    func start(
        _ operation: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) {
        let superseded = task
        task = nil
        activeAttemptID = nil
        superseded?.cancel()

        let attemptID = UUID()
        activeAttemptID = attemptID
        task = Task { [weak self] in
            await operation { [weak self] in self?.activeAttemptID == attemptID }
            // A superseded attempt may unwind after the user has already
            // started another one. It must not clear the newer attempt's
            // running state or task handle (the AddAccountView.run race).
            guard let self, self.activeAttemptID == attemptID else { return }
            self.activeAttemptID = nil
            self.task = nil
        }
    }

    /// Invalidate the attempt identity before cancelling its Task, mirroring
    /// AddAccountView.cancelLinking: asynchronous unwinding then observes a
    /// stale identity and publishes nothing.
    func cancel() {
        activeAttemptID = nil
        let running = task
        task = nil
        running?.cancel()
    }
}
