#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// BGAppRefreshTask wiring — opportunistic by design; iOS decides when.
/// We are honest about this in-product (docs/architecture.md fetch triggers).
enum BackgroundRefresh {
    private static let log = Logger(subsystem: "app.vigil", category: "background")

    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SharedContainer.refreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, model: model)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: SharedContainer.refreshTaskID)
        // The ledger enforces the real floor; this only hints iOS.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Could not schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask, model: AppModel) {
        schedule() // keep the chain alive

        // setTaskCompleted must fire exactly once — the work Task and the
        // expiration handler race on process suspension.
        let completed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func completeOnce(success: Bool) {
            let isFirst = completed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if isFirst { task.setTaskCompleted(success: success) }
        }

        let work = Task {
            await model.refreshAll(surface: "bgtask")
            completeOnce(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            completeOnce(success: false)
        }
    }
}
#endif
