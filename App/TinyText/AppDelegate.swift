import CloudKit
import UIKit

/// UIKit-level lifecycle that SwiftUI does not expose: registering for the
/// silent CloudKit push and handling the subscription notification. All
/// CloudKit work is delegated to `CloudTextStore`; this type only routes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent, content-available CloudKit pushes carry no alert, so they need
        // no user-facing permission prompt; registering at launch is enough.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Only our subscription's pushes are actionable. Anything else is no data.
        guard
            let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
            notification.subscriptionID == CloudTextStore.subscriptionID
        else {
            completionHandler(.noData)
            return
        }

        // CloudKit may coalesce subscription notifications, so the push is only a
        // signal to fetch authoritative state rather than trusting payload fields.
        // The delegate is @MainActor, so this Task stays on the main actor and the
        // completion handler is invoked exactly once when the fetch finishes.
        Task {
            let result: UIBackgroundFetchResult
            switch await CloudTextStore.shared.fetchLatest() {
            case .updated: result = .newData
            case .unchanged: result = .noData
            case .failed: result = .failed
            }
            completionHandler(result)
        }
    }
}
