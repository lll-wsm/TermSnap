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
    static var shortcutCaptureKeyCode: Int {
        get { defaults.integer(forKey: "shortcutCaptureKeyCode") }
        set { defaults.set(newValue, forKey: "shortcutCaptureKeyCode") }
    }
    static var shortcutCaptureModifiers: UInt {
        get { UInt(defaults.integer(forKey: "shortcutCaptureModifiers")) }
        set { defaults.set(Int(newValue), forKey: "shortcutCaptureModifiers") }
    }
    static var showFinderIcon: Bool {
        get { defaults.bool(forKey: "showFinderIcon") }
        set { defaults.set(newValue, forKey: "showFinderIcon") }
    }

    static var enabledTemplates: [String] {
        get { defaults.stringArray(forKey: "enabledTemplates") ?? [] }
        set { defaults.set(newValue, forKey: "enabledTemplates") }
    }
    static var showTemplateIcons: Bool {
        get { defaults.object(forKey: "showTemplateIcons") == nil ? true : defaults.bool(forKey: "showTemplateIcons") }
        set { defaults.set(newValue, forKey: "showTemplateIcons") }
    }
    static var showCreateFileMenu: Bool {
        get { defaults.object(forKey: "showCreateFileMenu") == nil ? true : defaults.bool(forKey: "showCreateFileMenu") }
        set { defaults.set(newValue, forKey: "showCreateFileMenu") }
    }
    static var showTerminalMenu: Bool {
        get { defaults.object(forKey: "showTerminalMenu") == nil ? true : defaults.bool(forKey: "showTerminalMenu") }
        set { defaults.set(newValue, forKey: "showTerminalMenu") }
    }
    static var showCopyPathMenu: Bool {
        get { defaults.object(forKey: "showCopyPathMenu") == nil ? true : defaults.bool(forKey: "showCopyPathMenu") }
        set { defaults.set(newValue, forKey: "showCopyPathMenu") }
    }
    static var menuLayout: String {
        get { defaults.string(forKey: "menuLayout") ?? "nested" }
        set { defaults.set(newValue, forKey: "menuLayout") }
    }
}
