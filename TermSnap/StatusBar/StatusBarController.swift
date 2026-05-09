import AppKit
import SwiftUI

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let captureEngine = CaptureEngine()

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "PhysalisStatusIcon")
            button.image?.size = NSSize(width: 24, height: 24)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(makeItem(NSLocalizedString("Take Screenshot", comment: ""), action: #selector(captureScreenshot), key: "x"))
        menu.addItem(makeItem(NSLocalizedString("Scrolling Screenshot", comment: ""), action: #selector(startScrollingScreenshot), key: "s"))
        menu.addItem(makeItem(NSLocalizedString("Enable Finder Extension", comment: ""), action: #selector(openExtensionGuide), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem(NSLocalizedString("Settings", comment: ""), action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(title: NSLocalizedString("Quit TermSnap", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func captureScreenshot() {
        Task {
            let result = await captureEngine.capture(.interactive)
            switch result {
            case .started:
                break
            case .permissionDenied:
                presentScreenCapturePermissionAlert()
            case .failed(let reason):
                presentCaptureFailedAlert(reason: reason)
            }
        }
    }

    @objc private func startScrollingScreenshot() {
        Task {
            let result = await captureEngine.capture(.scrolling)
            switch result {
            case .started:
                break
            case .permissionDenied:
                presentScreenCapturePermissionAlert()
            case .failed(let reason):
                presentCaptureFailedAlert(reason: reason)
            }
        }
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.title = NSLocalizedString("Settings", comment: "")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkExtensionEnabled() {
        let hasShownGuide = UserDefaults.standard.bool(forKey: "hasShownExtensionGuide")
        guard !hasShownGuide else { return }

        UserDefaults.standard.set(true, forKey: "hasShownExtensionGuide")
        presentExtensionGuide()
    }

    @objc private func openExtensionGuide() {
        presentExtensionGuide()
    }

    private func presentExtensionGuide() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "TermSnap"
        panel.contentView = NSHostingView(rootView: ExtensionGuideView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentScreenCapturePermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Screen Recording Permission Required", comment: "")
        alert.informativeText = NSLocalizedString("TermSnap needs Screen Recording permission to capture screenshots. You can enable it in System Settings > Privacy & Security > Screen Recording.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentCaptureFailedAlert(reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Failed to Capture Screenshot", comment: "")
        alert.informativeText = reason
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}
