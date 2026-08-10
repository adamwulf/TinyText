import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    // Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist.
    static let taskIdentifier = "com.milestonemade.tinytext.sync"

    private static let minimumInterval: TimeInterval = 60 * 60

    /// Coordinates a background fetch and its `BGAppRefreshTask`. The expiration
    /// handler and the fetch's completion run on different threads and race, so a
    /// lock guards a single `setTaskCompleted` call and lets expiration report
    /// failure immediately without waiting for a delayed network callback.
    /// `@unchecked Sendable` because it owns a non-Sendable `BGTask` behind its lock.
    private final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private let task: BGAppRefreshTask
        private var work: Task<Void, Never>?
        private var expired = false
        private var completed = false

        init(_ task: BGAppRefreshTask) {
            self.task = task
        }

        /// Attach the fetch task. If expiration already fired, cancel it at once.
        func attach(_ work: Task<Void, Never>) {
            lock.lock()
            self.work = work
            let alreadyExpired = expired
            lock.unlock()
            if alreadyExpired { work.cancel() }
        }

        /// From the expiration handler: cancel the in-flight fetch and fail now.
        func expire() {
            lock.lock()
            expired = true
            let work = self.work
            lock.unlock()
            work?.cancel()
            complete(success: false)
        }

        /// From the fetch completion: report the outcome (ignored after expiry).
        func finish(success: Bool) {
            complete(success: success)
        }

        private func complete(success: Bool) {
            lock.lock()
            let wasCompleted = completed
            completed = true
            lock.unlock()
            guard !wasCompleted else { return }
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
        task.expirationHandler = {
            coordinator.expire()
        }

        let work = Task {
            let outcome = await CloudTextStore.shared.fetchLatest()
            coordinator.finish(success: outcome != .failed)
        }
        coordinator.attach(work)
    }
}
