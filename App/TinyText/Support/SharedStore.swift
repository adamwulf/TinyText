import Foundation
import WidgetKit

enum SharedStore {
    static let appGroupID = "group.com.milestonemade.tinytext"
    static let textKey = "tinytext.text"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func loadText() -> String {
        defaults.string(forKey: textKey) ?? ""
    }

    static func saveText(_ text: String) {
        defaults.set(text, forKey: textKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
