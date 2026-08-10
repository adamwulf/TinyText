import Foundation
import WidgetKit

enum SharedStore {
    static let appGroupID = "group.com.milestonemade.tinytext"
    static let textKey = "tinytext.text"
    static let textDidChangeNotification = Notification.Name("SharedStore.textDidChange")

    private static let widgetKind = "TinyTextWidget"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func loadText() -> String {
        defaults.string(forKey: textKey) ?? ""
    }

    @discardableResult
    static func saveText(_ text: String) -> Bool {
        guard defaults.string(forKey: textKey) != text else { return false }
        defaults.set(text, forKey: textKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        return true
    }

    static func applyRemoteText(_ text: String) {
        guard saveText(text) else { return }
        NotificationCenter.default.post(name: textDidChangeNotification, object: nil)
    }
}
