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
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/TermSnap")
    }()
    
    var templatesDir: URL { configDir.appendingPathComponent("Templates") }
    var iconsDir: URL { configDir.appendingPathComponent("Icons") }
    
    @Published var availableTemplates: [URL] = []
    
    init() {
        setupDirectories()
        refreshTemplates()
    }
    

    
    func setupDirectories() {
        let fm = FileManager.default
        
        // Ensure real directories exist in Group Container (Source of truth)
        try? fm.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
    }
    
    func refreshTemplates() {
        let files = try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)
        availableTemplates = files?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
    }
    
    func getEnabledTemplates() -> [URL] {
        refreshTemplates()
        let enabled = AppSettings.enabledTemplates
        return availableTemplates.filter { enabled.contains($0.lastPathComponent) }
    }
    
    func openTemplatesFolder() {
        NSWorkspace.shared.open(templatesDir)
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
