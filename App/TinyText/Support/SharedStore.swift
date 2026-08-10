import Foundation
import WidgetKit

enum SharedStore {
    static let appGroupID = "group.com.milestonemade.tinytext"
    static let textKey = "tinytext.text"
    static let textDidChangeNotification = Notification.Name("SharedStore.textDidChange")

    private static let dirtyKey = "tinytext.dirty"
    private static let widgetKind = "TinyTextWidget"

    // Serializes cache + dirty-marker mutations so a local edit and a conditional
    // remote apply can never interleave. This closes the window between
    // CloudTextStore's fetch guard and the apply below.
    private static let lock = NSLock()

    /// Outcome of a conditional remote apply, so the caller's fetch outcome stays accurate.
    enum RemoteApply {
        case applied(changed: Bool)
        case refusedDirty
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func loadText() -> String {
        defaults.string(forKey: textKey) ?? ""
    }

    /// True while the cache holds a local edit not yet confirmed on the server.
    /// Durable across relaunch/force-quit because it lives in the App Group.
    static var isDirty: Bool {
        defaults.bool(forKey: dirtyKey)
    }

    /// A local edit. Writes the cache and marks it dirty synchronously, so a
    /// crash before the upload cannot lose the edit. Returns whether the value
    /// changed; only a real change reloads the widget and warrants a cloud save.
    @discardableResult
    static func saveText(_ text: String) -> Bool {
        lock.lock()
        let changed = loadTextLocked() != text
        if changed {
            defaults.set(text, forKey: textKey)
            defaults.set(true, forKey: dirtyKey)
        }
        lock.unlock()

        if changed {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
        return changed
    }

    /// Apply an authoritative server value. Refuses when the cache is dirty, so a
    /// slow or older fetch can never erase an unsynced local edit. Otherwise the
    /// cache now equals the server value, so it stays clean. Returns whether it
    /// changed the cache.
    static func applyRemoteText(_ text: String) -> RemoteApply {
        lock.lock()
        guard !defaults.bool(forKey: dirtyKey) else {
            lock.unlock()
            return .refusedDirty
        }
        let changed = loadTextLocked() != text
        if changed {
            defaults.set(text, forKey: textKey)
        }
        lock.unlock()

        // Widget reload and editor notification happen after the mutation and
        // outside the lock.
        if changed {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            NotificationCenter.default.post(name: textDidChangeNotification, object: nil)
        }
        return .applied(changed: changed)
    }

    /// Clear the dirty marker after a successful upload, but only if the cache
    /// still equals the text that was actually written; a newer local edit keeps
    /// the cache dirty so its own upload can follow.
    static func clearDirty(ifTextEquals text: String) {
        lock.lock()
        if loadTextLocked() == text {
            defaults.set(false, forKey: dirtyKey)
        }
        lock.unlock()
    }

    private static func loadTextLocked() -> String {
        defaults.string(forKey: textKey) ?? ""
    }
}
