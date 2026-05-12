import FinderSync
import Foundation
import AppKit
import OSLog

class FinderSyncExtension: FIFinderSync {
    
    private let logger = OSLog(subsystem: "com.lll.TermSnap", category: "FinderExtension")
    private let suiteName = "group.com.lll.TermSnap"
    private let darwinNotificationName = "com.lll.TermSnap.request"
    
    override init() {
        super.init()
        os_log("TermSnapExtension: Initializing", log: logger, type: .info)
        
        let locator = FIFinderSyncController.default()
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        locator.directoryURLs = [root]
    }

    private func notifyMainApp() {
        // Post Darwin Notification (most robust cross-process trigger)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinNotificationName as CFString), nil, nil, true)
    }

    // MARK: - Menu Construction
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Sync defaults
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.synchronize()
        
        os_log("TermSnapExtension: Building menu (kind=%{public}d)", log: logger, type: .info, menuKind.rawValue)
        
        let rootMenu = NSMenu(title: "")
        let containerMenu: NSMenu
        
        // Manual check of settings to be safe
        let menuLayout = defaults?.string(forKey: "menuLayout") ?? "nested"
        let showTerminalMenu = defaults?.object(forKey: "showTerminalMenu") == nil ? true : (defaults?.bool(forKey: "showTerminalMenu") ?? true)
        let showCreateFileMenu = defaults?.object(forKey: "showCreateFileMenu") == nil ? true : (defaults?.bool(forKey: "showCreateFileMenu") ?? true)
        let showFinderIcon = defaults?.bool(forKey: "showFinderIcon") ?? false
        
        if menuLayout == "nested" {
            let mainItem = rootMenu.addItem(withTitle: "TermSnap", action: nil, keyEquivalent: "")
            if showFinderIcon {
                mainItem.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "TermSnap")
            }
            let submenu = NSMenu(title: "TermSnap")
            rootMenu.setSubmenu(submenu, for: mainItem)
            containerMenu = submenu
        } else {
            containerMenu = rootMenu
        }
        
        if showTerminalMenu {
            let title = NSLocalizedString("Open Terminal Here", comment: "")
            let item = containerMenu.addItem(withTitle: title, action: #selector(openTerminalAction(_:)), keyEquivalent: "")
            item.target = self
            if showFinderIcon {
                item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            }
        }
        
        if showCreateFileMenu {
            let templates = TemplateManager.shared.getEnabledTemplates()
            os_log("TermSnapExtension: CreateFile menu - showCreateFileMenu=true templateCount=%{public}d availableCount=%{public}d enabledList=%{public}s", log: logger, type: .info, templates.count, TemplateManager.shared.availableTemplates.count, AppSettings.enabledTemplates.joined(separator: ", "))
            if !templates.isEmpty {
                let title = NSLocalizedString("Create New File", comment: "")
                let createFileItem = containerMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                let createFileSubmenu = NSMenu(title: title)
                containerMenu.setSubmenu(createFileSubmenu, for: createFileItem)
                
                for template in templates {
                    let item = createFileSubmenu.addItem(withTitle: template.lastPathComponent, action: #selector(createFileAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = template.path
                    if AppSettings.showTemplateIcons {
                        item.image = TemplateManager.shared.getIcon(for: template)
                    }
                }
            }
        }
        
        return rootMenu
    }

    // MARK: - Actions
    
    @objc func openTerminalAction(_ sender: AnyObject?) {
        let path = getTargetURL().path
        os_log("TermSnapExtension: Requesting Terminal at %{public}s", log: logger, type: .info, path)
        
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(path, forKey: "lastOpenTerminalPath")
            defaults.synchronize()
            notifyMainApp()
        }
    }

    @objc func createFileAction(_ sender: AnyObject?) {
        os_log("TermSnapExtension: createFileAction triggered", log: logger, type: .info)

        guard let menuItem = sender as? NSMenuItem else {
            os_log("TermSnapExtension: sender is NOT NSMenuItem", log: logger, type: .error)
            return
        }

        // Finder may not preserve representedObject on submenu items,
        // so use the menu title (template filename) to reconstruct the path.
        let templateURL = TemplateManager.shared.templatesDir.appendingPathComponent(menuItem.title)
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            os_log("TermSnapExtension: template not found at %{public}s", log: logger, type: .error, templateURL.path)
            return
        }
        let templatePath = templateURL.path
        let targetDirPath = getTargetURL().path

        os_log("TermSnapExtension: Requesting CreateFile for %{public}s", log: logger, type: .info, templatePath)

        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(templatePath, forKey: "createFileTemplatePath")
            defaults.set(targetDirPath, forKey: "createFileTargetDir")
            defaults.synchronize()
            notifyMainApp()
        }
    }
    
    private func getTargetURL() -> URL {
        let controller = FIFinderSyncController.default()
        if let selectedURL = controller.selectedItemURLs()?.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDir), isDir.boolValue {
                return selectedURL
            }
        }
        return controller.targetedURL() ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}
