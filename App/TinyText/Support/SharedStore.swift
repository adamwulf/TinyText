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
        if let cloudText = cloud.string(forKey: textKey),
           cloudText != defaults.string(forKey: textKey) {
            defaults.set(cloudText, forKey: textKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
        cloud.synchronize()
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
