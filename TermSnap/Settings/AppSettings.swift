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
    static var shortcutCapture: String {
        get { defaults.string(forKey: "shortcutCapture") ?? "" }
        set { defaults.set(newValue, forKey: "shortcutCapture") }
    }
    static var showFinderIcon: Bool {
        get { defaults.bool(forKey: "showFinderIcon") }
        set { defaults.set(newValue, forKey: "showFinderIcon") }
    }
}
