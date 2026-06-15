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
        let cloudText = cloud.string(forKey: textKey)
        let localText = defaults.string(forKey: textKey)
        if let cloudText, cloudText != localText {
            defaults.set(cloudText, forKey: textKey)
            WidgetCenter.shared.reloadAllTimelines()
        } else if let localText, cloudText == nil {
            cloud.set(localText, forKey: textKey)
        }
        cloud.synchronize()
    }

    static func loadText() -> String {
        defaults.string(forKey: textKey) ?? ""
    }

    static func saveText(_ text: String) {
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
        defaults.set(newValue, forKey: textKey)
        WidgetCenter.shared.reloadAllTimelines()
        return newValue
    }
}
