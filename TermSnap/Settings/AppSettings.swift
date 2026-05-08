import Foundation

enum AppSettings {
    private static let defaults = UserDefaults(suiteName: "group.com.lll.TermSnap")!

    static var saveFormat: String {
        get { defaults.string(forKey: "saveFormat") ?? "png" }
        set { defaults.set(newValue, forKey: "saveFormat") }
    }
    static var saveDirectory: String {
        get { defaults.string(forKey: "saveDirectory") ?? "" }
        set { defaults.set(newValue, forKey: "saveDirectory") }
    }
    static var shortcutFullScreen: String {
        get { defaults.string(forKey: "shortcutFullScreen") ?? "" }
        set { defaults.set(newValue, forKey: "shortcutFullScreen") }
    }
    static var shortcutArea: String {
        get { defaults.string(forKey: "shortcutArea") ?? "" }
        set { defaults.set(newValue, forKey: "shortcutArea") }
    }
    static var shortcutWindow: String {
        get { defaults.string(forKey: "shortcutWindow") ?? "" }
        set { defaults.set(newValue, forKey: "shortcutWindow") }
    }
}
