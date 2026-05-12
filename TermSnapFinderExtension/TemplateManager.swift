import Foundation
import AppKit
import Combine

class TemplateManager: ObservableObject {
    static let shared = TemplateManager()
    
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
    
    func setupDirectories() {
        try? FileManager.default.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        
        // Create symlink in ~/.config/TermSnap for easier user access
        let userConfigDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/TermSnap")
        if !FileManager.default.fileExists(atPath: userConfigDir.path) {
            try? FileManager.default.createDirectory(at: userConfigDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: userConfigDir, withDestinationURL: configDir)
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
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: templatesDir.path)
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
        
        return NSWorkspace.shared.icon(forFileType: template.pathExtension)
    }
}
