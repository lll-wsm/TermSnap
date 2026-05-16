import Foundation
import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

class TemplateManager: ObservableObject {
    static let shared = TemplateManager()
    private let logger = OSLog(subsystem: "com.lll.TermSnap", category: "TemplateManager")
    
    let configDir: URL = {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lll.TermSnap") {
            return groupURL
        }
        // Fallback for non-sandboxed main app if App Group fails (should not happen)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/TermSnap")
    }()
    
    var templatesDir: URL { configDir.appendingPathComponent("Templates") }
    var iconsDir: URL { configDir.appendingPathComponent("Icons") }
    
    @Published var availableTemplates: [URL] = []
    
    init() {
        setupDirectories()
        refreshTemplates()
    }
    
    private var userConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/TermSnap")
    }
    
    func setupDirectories() {
        let fm = FileManager.default
        
        // 1. Ensure real directories exist in Group Container (Source of truth)
        try? fm.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        
        // 2. Handle ~/.config/TermSnap (User-facing path)
        let userConfigPath = userConfigDir.path
        
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: userConfigPath, isDirectory: &isDir) {
            let attributes = try? fm.attributesOfItem(atPath: userConfigPath)
            let isSymbolicLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
            
            if !isSymbolicLink && isDir.boolValue {
                // CRITICAL: It's a REAL directory. Migrate and replace.
                os_log("TermSnap: Migrating real directory at ~/.config/TermSnap to App Group", log: self.logger, type: .info)
                migrateDirectoryContents(from: userConfigDir, to: configDir)
                
                do {
                    try fm.removeItem(at: userConfigDir)
                } catch {
                    os_log("TermSnap: Failed to remove old directory: %{public}s", log: self.logger, type: .error, error.localizedDescription)
                    // If remove failed, just rename it to clear the path
                    try? fm.moveItem(at: userConfigDir, to: userConfigDir.appendingPathExtension("bak"))
                }
            }
        }
        
        // 3. Create or fix the symlink
        var shouldCreateSymlink = false
        if !fm.fileExists(atPath: userConfigPath) {
            shouldCreateSymlink = true
        } else {
            // Check if existing symlink points to the right place
            let attributes = try? fm.attributesOfItem(atPath: userConfigPath)
            if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                let destination = try? fm.destinationOfSymbolicLink(atPath: userConfigPath)
                if destination != configDir.path {
                    try? fm.removeItem(at: userConfigDir)
                    shouldCreateSymlink = true
                }
            }
        }
        
        if shouldCreateSymlink {
            let parentDir = userConfigDir.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            
            do {
                try fm.createSymbolicLink(at: userConfigDir, withDestinationURL: configDir)
                os_log("TermSnap: Created/Fixed symlink ~/.config/TermSnap -> App Group", log: self.logger, type: .info)
            } catch {
                os_log("TermSnap: Failed to create symlink: %{public}s", log: self.logger, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func migrateDirectoryContents(from source: URL, to destination: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        
        for item in items {
            let targetURL = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: targetURL.path) {
                try? fm.removeItem(at: targetURL)
            }
            try? fm.moveItem(at: item, to: targetURL)
        }
    }
    
    func refreshTemplates() {
        let files = try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)
        availableTemplates = files?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
    }
    
    func getEnabledTemplates() -> [URL] {
        let enabled = AppSettings.enabledTemplates
        return availableTemplates.filter { enabled.contains($0.lastPathComponent) }
    }
    
    func openTemplatesFolder() {
        let userTemplatesDir = userConfigDir.appendingPathComponent("Templates")
        // Open the user-facing symlink path subfolder specifically
        if FileManager.default.fileExists(atPath: userTemplatesDir.path) {
            NSWorkspace.shared.open(userTemplatesDir)
        } else {
            // Fallback to the real path if symlink is missing
            NSWorkspace.shared.open(templatesDir)
        }
    }
    
    func getIcon(for template: URL) -> NSImage {
        let fileName = template.deletingPathExtension().lastPathComponent
        let customIconPaths = [
            iconsDir.appendingPathComponent("\(fileName).png"),
            iconsDir.appendingPathComponent("\(fileName).pdf")
        ]
        
        for path in customIconPaths {
            if FileManager.default.fileExists(atPath: path.path), let image = NSImage(contentsOfFile: path.path) {
                return image
            }
        }
        
        if let utType = UTType(filenameExtension: template.pathExtension) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }
}
