import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    static let taskIdentifier = "com.milestonemade.tinytext.sync"

    private static let minimumInterval: TimeInterval = 60 * 60

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask)
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
        schedule()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        SharedStore.refreshFromCloud()
        task.setTaskCompleted(success: true)
    }
}
