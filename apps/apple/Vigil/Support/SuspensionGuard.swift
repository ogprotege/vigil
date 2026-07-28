import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Holds a UIApplication background-task assertion across short critical
/// sections that own cross-process file locks (the history flock and SQLite
/// WAL locks).
///
/// iOS kills a suspended process that still holds file locks
/// (RUNNINGBOARD 0xdead10cc). History reads run on a detached queue and
/// history/snapshot writes run inside fetches that can outlive the
/// foreground — including the BGAppRefreshTask path, whose completion hands
/// the process back to the suspendor — so without an assertion the system
/// can suspend the app mid-lock. The assertion defers suspension until the
/// locks are released.
///
/// This lives in the app target on purpose: VigilKit stays UI-free and the
/// widget extension cannot touch UIApplication.
enum SuspensionGuard {
    static func withProtection<T>(named name: String, _ body: () throws -> T) rethrows -> T {
        #if canImport(UIKit)
        let assertion = BackgroundTaskAssertion(name: name)
        defer { assertion.end() }
        #endif
        return try body()
    }

    static func withProtection<T>(
        named name: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        #if canImport(UIKit)
        let assertion = BackgroundTaskAssertion(name: name)
        defer { assertion.end() }
        #endif
        return try await body()
    }
}

#if canImport(UIKit)
/// UIApplication permits begin/endBackgroundTask from any thread, but the
/// expiration handler arrives on the main queue and can race the defer that
/// ends the assertion normally, so ending is made idempotent under a lock.
private final class BackgroundTaskAssertion: @unchecked Sendable {
    private let application: UIApplication
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        let application = UIApplication.shared
        self.application = application
        // If the expiration handler fires before the assignment lands, its
        // end() is a no-op and the defer in withProtection ends the token.
        identifier = application.beginBackgroundTask(withName: name) { [weak self] in
            // Expiry requires ending the assertion immediately or the
            // watchdog kills the app. The guarded work keeps running but the
            // app may suspend once it finishes.
            self?.end()
        }
    }

    func end() {
        lock.lock()
        let ended = identifier
        identifier = .invalid
        lock.unlock()
        guard ended != .invalid else { return }
        application.endBackgroundTask(ended)
    }
}
#endif
