import Foundation

enum AppGroupConstants {
    static let groupIdentifier = "group.com.lll.TermSnap"
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: groupIdentifier)!
    }
}
