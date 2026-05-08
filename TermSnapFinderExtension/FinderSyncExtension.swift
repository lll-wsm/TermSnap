import FinderSync
import Foundation

class FinderSyncExtension: FIFinderSync {
    private let openTerminalNotificationName = Notification.Name("com.lll.TermSnap.openTerminalRequest")
    private let directoryPathKey = "directoryPath"

    override init() {
        super.init()
        let locator = FIFinderSyncController.default()
        
        // Root and common volumes to ensure coverage
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        locator.directoryURLs = [root, volumes]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Terminal Here",
                              action: #selector(openTerminalHere),
                              keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        menu.addItem(item)
        return menu
    }

    @objc func openTerminalHere() {
        let controller = FIFinderSyncController.default()
        let directoryURL = resolveDirectoryURL(selectedURLs: controller.selectedItemURLs(),
                                               targetedURL: controller.targetedURL())
        
        NSLog("TermSnapExtension: Triggering open request for path: \(directoryURL.path)")
        
        // Use App Group shared UserDefaults directly
        if let defaults = UserDefaults(suiteName: "group.com.lll.TermSnap") {
            defaults.set(directoryURL.path, forKey: "lastOpenTerminalPath")
            // Use a timestamp to trigger the observer in the main app
            defaults.set(Date().timeIntervalSince1970, forKey: "openTerminalTrigger")
            defaults.synchronize()
        }
    }

    private func resolveDirectoryURL(selectedURLs: [URL]?, targetedURL: URL?) -> URL {
        if let firstSelected = selectedURLs?.first {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: firstSelected.path, isDirectory: &isDir)
            if isDir.boolValue {
                return firstSelected
            }
            return firstSelected.deletingLastPathComponent()
        }

        if let target = targetedURL {
            return target
        }

        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
