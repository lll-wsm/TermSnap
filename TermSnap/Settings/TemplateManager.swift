import Foundation
import AppKit
import Combine

class TemplateManager: ObservableObject {
    static let shared = TemplateManager()
    
    let configDir: URL = {
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
    }
    
    func refreshTemplates() {
        let files = try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)
        availableTemplates = files?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
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
