import Foundation
import WidgetKit

enum SharedStore {
    static let appGroupID = "group.com.milestonemade.tinytext"
    static let textKey = "tinytext.text"
    private static let didSeedCloudKey = "tinytext.didSeedCloud"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private static var cloud: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }

    static func start() {
        let cloudText = cloud.string(forKey: textKey)
        let localText = defaults.string(forKey: textKey)
        let didSeed = defaults.bool(forKey: didSeedCloudKey)

        if let cloudText, cloudText != localText {
            defaults.set(cloudText, forKey: textKey)
            WidgetCenter.shared.reloadAllTimelines()
        } else if !didSeed, cloudText == nil, let localText, !localText.isEmpty {
            cloud.set(localText, forKey: textKey)
            defaults.set(true, forKey: didSeedCloudKey)
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
        defaults.set(true, forKey: didSeedCloudKey)
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
        defaults.set(true, forKey: didSeedCloudKey)
        WidgetCenter.shared.reloadAllTimelines()
        return newValue
    }
}
