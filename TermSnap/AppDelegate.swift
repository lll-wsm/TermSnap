import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBarController = StatusBarController()
    private var terminalOpenObserver: NSObjectProtocol?
    private let openTerminalNotificationName = Notification.Name("com.lll.TermSnap.openTerminalRequest")
    private let directoryPathKey = "directoryPath"

    private let sharedDefaults = UserDefaults(suiteName: "group.com.lll.TermSnap")!
    private let triggerKey = "openTerminalTrigger"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.setup()
        startObservingTerminalOpenRequests()

        // Check once immediately in case a request came in while app was closed
        processLastTerminalRequest()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.statusBarController.checkExtensionEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sharedDefaults.removeObserver(self, forKeyPath: triggerKey)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func startObservingTerminalOpenRequests() {
        NSLog("TermSnap: Starting low-level observation of App Group.")
        
        // Low-level KVO is the most robust way for cross-process UserDefaults monitoring
        sharedDefaults.addObserver(self, forKeyPath: triggerKey, options: .new, context: nil)
        
        // Backup observer for general changes
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: sharedDefaults,
                                               queue: .main) { [weak self] _ in
            NSLog("TermSnap: Notification backup triggered.")
            self?.processLastTerminalRequest()
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == triggerKey {
            NSLog("TermSnap: Low-level KVO triggered for \(triggerKey)")
            processLastTerminalRequest()
        }
    }

    private func processLastTerminalRequest() {
        let path = sharedDefaults.string(forKey: "lastOpenTerminalPath") ?? ""
        if !path.isEmpty {
            NSLog("TermSnap: Processing terminal request for: \(path)")
            Task { @MainActor in
                TerminalLauncher.openDirectory(path)
                // Clear the path after starting process to avoid re-triggering
                sharedDefaults.removeObject(forKey: "lastOpenTerminalPath")
                sharedDefaults.synchronize()
            }
        }
    }
}
