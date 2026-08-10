import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    // Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist.
    static let taskIdentifier = "com.milestonemade.tinytext.sync"

    private static let minimumInterval: TimeInterval = 60 * 60

    /// Coordinates a background fetch and its `BGAppRefreshTask`. The expiration
    /// handler and the fetch's completion run on different threads and race; one
    /// lock picks the single winner, which reports failure immediately on
    /// expiration without waiting for a delayed network callback. `@unchecked
    /// Sendable` because it owns a non-Sendable `BGTask` behind its lock.
    private final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private let task: BGAppRefreshTask
        private var work: Task<Void, Never>?
        private var finished = false

        init(_ task: BGAppRefreshTask) {
            self.task = task
        }

        /// Attach the fetch task. If the task already finished (expired or
        /// completed), cancel it and do not retain it.
        func attach(_ work: Task<Void, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                work.cancel()
                return
            }
            self.work = work
            lock.unlock()
        }

        /// From the expiration handler: fail now (cancels the in-flight fetch).
        func expire() {
            complete(success: false)
        }

        /// From the fetch completion: report the outcome (ignored after expiry).
        func finish(success: Bool) {
            complete(success: success)
        }

        /// The single winner path: the first caller completes the task; later
        /// callers are ignored. Releases the fetch task so neither a
        /// Coordinator↔work nor a task→handler→Coordinator cycle outlives the run.
        private func complete(success: Bool) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let work = self.work
            self.work = nil
            lock.unlock()

            work?.cancel()
            task.setTaskCompleted(success: success)
        }
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

        let coordinator = Coordinator(task)

        // Install expiration handling before starting the fetch so an early
        // expiration always cancels the work and completes the task exactly once.
        // Weak so the task's handler never forms a retain cycle with the coordinator.
        task.expirationHandler = { [weak coordinator] in
            coordinator?.expire()
        }

        // The work task holds the coordinator strongly, keeping it alive for the
        // run; the coordinator drops the work reference as soon as it completes.
        let work = Task {
            let outcome = await CloudTextStore.shared.fetchLatest()
            coordinator.finish(success: outcome != .failed)
        }
        coordinator.attach(work)
    }
}
