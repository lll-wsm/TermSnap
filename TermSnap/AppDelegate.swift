import SwiftUI
import OSLog

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBarController = StatusBarController()
    
    private let sharedDefaults = UserDefaults(suiteName: "group.com.lll.TermSnap")!
    private let logger = OSLog(subsystem: "com.lll.TermSnap", category: "AppDelegate")
    private let darwinNotificationName = "com.lll.TermSnap.request"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.setup()
        
        // Register global shortcut
        setupGlobalShortcut()
        
        // Listen for shortcut changes from Settings
        NotificationCenter.default.addObserver(self, selector: #selector(setupGlobalShortcut), name: Notification.Name("ShortcutChanged"), object: nil)
        
        // Listen for Darwin Notifications
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        CFNotificationCenterAddObserver(center,
                                        observer,
                                        { (center, observer, name, object, userInfo) in
                                            guard let observer = observer else { return }
                                            let mySelf = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                                            mySelf.processRequests()
                                        },
                                        darwinNotificationName as CFString,
                                        nil,
                                        .deliverImmediately)
        
        // Initial check
        processRequests()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.statusBarController.checkExtensionEnabled()
        }
    }

    @objc private func setupGlobalShortcut() {
        let keyCode = AppSettings.shortcutCaptureKeyCode
        let modifiers = AppSettings.shortcutCaptureModifiers
        
        if keyCode > 0 {
            GlobalShortcutManager.shared.register(keyCode: keyCode, modifiers: modifiers) { [weak self] in
                self?.statusBarController.captureScreenshot()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        GlobalShortcutManager.shared.unregister()
    }

    // MARK: - Processor
    
    @objc private func processRequests() {
        sharedDefaults.synchronize()
        
        // 1. Process Terminal Request
        let terminalPath = sharedDefaults.string(forKey: "lastOpenTerminalPath") ?? ""
        if !terminalPath.isEmpty {
            os_log("TermSnap: Processing Terminal Open for %{public}s", log: logger, type: .info, terminalPath)
            Task { @MainActor in
                TerminalLauncher.openDirectory(terminalPath)
                sharedDefaults.removeObject(forKey: "lastOpenTerminalPath")
                sharedDefaults.synchronize()
            }
        }
        
        // 2. Process File Creation Request
        let templatePath = sharedDefaults.string(forKey: "createFileTemplatePath") ?? ""
        let targetDirPath = sharedDefaults.string(forKey: "createFileTargetDir") ?? ""
        
        if !templatePath.isEmpty && !targetDirPath.isEmpty {
            os_log("TermSnap: Processing File Creation request", log: logger, type: .info)
            os_log("TermSnap: Template: %{public}s", log: logger, type: .info, templatePath)
            os_log("TermSnap: TargetDir: %{public}s", log: logger, type: .info, targetDirPath)
            
            let templateURL = URL(fileURLWithPath: templatePath)
            let targetDir = URL(fileURLWithPath: targetDirPath)
            
            // Validate template existence
            if !FileManager.default.fileExists(atPath: templateURL.path) {
                os_log("TermSnap: Error - Template file NOT FOUND at %{public}s", log: logger, type: .error, templateURL.path)
                clearCreateFileFlags()
                return
            }
            
            let fileName = templateURL.lastPathComponent
            var finalDestURL = targetDir.appendingPathComponent(fileName)
            
            // Collision handling
            var counter = 2
            let nameWithoutExt = templateURL.deletingPathExtension().lastPathComponent
            let ext = templateURL.pathExtension
            
            while FileManager.default.fileExists(atPath: finalDestURL.path) {
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                finalDestURL = targetDir.appendingPathComponent("\(nameWithoutExt) \(counter)\(suffix)")
                counter += 1
            }
            
            do {
                try FileManager.default.copyItem(at: templateURL, to: finalDestURL)
                os_log("TermSnap: SUCCESS! Created file at %{public}s", log: logger, type: .info, finalDestURL.path)
                
                clearCreateFileFlags()
                
                // Notify Finder the directory changed so the file appears without opening a window
                NSWorkspace.shared.noteFileSystemChanged(finalDestURL.path)
                
            } catch {
                os_log("TermSnap: Copy FAILED: %{public}s", log: logger, type: .error, error.localizedDescription)
                clearCreateFileFlags()
                
                // Last ditch effort: touch
                FileManager.default.createFile(atPath: finalDestURL.path, contents: nil, attributes: nil)
            }
        }
    }
    
    private func clearCreateFileFlags() {
        sharedDefaults.removeObject(forKey: "createFileTemplatePath")
        sharedDefaults.removeObject(forKey: "createFileTargetDir")
        sharedDefaults.synchronize()
    }
}
