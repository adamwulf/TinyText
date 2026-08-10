import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    // Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist.
    static let taskIdentifier = "com.milestonemade.tinytext.sync"

    private static let minimumInterval: TimeInterval = 60 * 60

    // `BGTask` predates Sendable but is safe to complete from background work
    // (that is its designed usage), so wrap it to hand the reference to the
    // async fetch below without a region-isolation violation.
    private struct UncheckedTask: @unchecked Sendable {
        let task: BGAppRefreshTask
    }

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may refuse the submission (e.g. simulator, background refresh disabled).
            // Nothing actionable here — foreground sync still works.
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        // Reschedule now so the chain continues even if this run is cut short.
        schedule()

        let boxed = UncheckedTask(task: task)

        // Fetch the authoritative record, then complete the task. This block is
        // the sole call site of `setTaskCompleted`, so completion happens exactly
        // once whether the fetch finishes or is cancelled on expiration.
        let work = Task {
            let outcome = await CloudTextStore.shared.fetchLatest()
            boxed.task.setTaskCompleted(success: outcome != .failed)
        }

        // Expiration cancels the in-flight fetch; the block above still reports
        // completion once when the (now cancelled) fetch returns.
        task.expirationHandler = {
            work.cancel()
        }
    }
}
