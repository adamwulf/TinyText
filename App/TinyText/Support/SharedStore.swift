import Foundation
import WidgetKit

enum SharedStore {
    static let appGroupID = "group.com.milestonemade.tinytext"
    static let textKey = "tinytext.text"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private static var cloud: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }

    static func start() {
        refreshFromCloud()
    }

    // Reads whatever NSUbiquitousKeyValueStore has cached locally and adopts it
    // if newer than our App Group copy. synchronize() does not fetch from iCloud —
    // remote updates arrive via APNs to the iCloud daemon independently. Calling
    // this from a BGAppRefreshTask gives the app a chance to pick up values the
    // daemon received while the app was suspended, and calling it from the
    // widget's timeline provider lets the widget pick up cross-device edits on
    // its own reload schedule, so it stays current without opening the app.
    //
    // Returns true when the App Group copy was updated. Reloads all widget
    // timelines only when running inside the containing app — a widget must not
    // reload itself from within its own timeline() call.
    @discardableResult
    static func refreshFromCloud() -> Bool {
        cloud.synchronize()
        guard let cloudText = cloud.string(forKey: textKey),
              cloudText != defaults.string(forKey: textKey) else {
            return false
        }
        defaults.set(cloudText, forKey: textKey)
        if !isWidgetProcess {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return true
    }

    // The widget extension runs in a process whose bundle identifier ends in
    // ".widget". We use this to avoid a widget reloading its own timeline.
    private static var isWidgetProcess: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".widget") ?? false
    }

    static func loadText() -> String {
        defaults.string(forKey: textKey) ?? ""
    }

    static func saveText(_ text: String) {
        if defaults.string(forKey: textKey) == text { return }
        defaults.set(text, forKey: textKey)
        cloud.set(text, forKey: textKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func applyExternalChange(_ note: Notification) -> String? {
        if let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
           !keys.contains(textKey) {
            return nil
        }
        guard let newValue = cloud.string(forKey: textKey) else { return nil }
        if defaults.string(forKey: textKey) == newValue { return nil }
        defaults.set(newValue, forKey: textKey)
        WidgetCenter.shared.reloadAllTimelines()
        return newValue
    }
}
