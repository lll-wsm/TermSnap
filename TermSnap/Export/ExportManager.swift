import AppKit
import UniformTypeIdentifiers

enum ExportManager {
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// Presents the save panel asynchronously (next run-loop turn) so it never runs nested
    /// inside the overlay toolbar’s gesture / tracking stack, which would otherwise deadlock.
    static func saveToFile(_ image: NSImage, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg]
            let ext = AppSettings.saveFormat
            panel.nameFieldStringValue = "TermSnap_\(timestampString()).\(ext)"
            panel.directoryURL = directoryURL()
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK, let url = panel.url else {
                completion(false)
                return
            }

            let format = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
                ? NSBitmapImageRep.FileType.jpeg
                : .png

            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                completion(false)
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = image.size // Critical: Tell the file its "points" size, not just pixel size

            guard let data = rep.representation(using: format, properties: [.compressionFactor: 0.9])
            else {
                completion(false)
                return
            }

            do {
                try data.write(to: url)
                completion(true)
            } catch {
                NSLog("TermSnap: Save error: \(error)")
                completion(false)
            }
        }
    }

    private static func directoryURL() -> URL {
        if !AppSettings.saveDirectory.isEmpty {
            return URL(fileURLWithPath: AppSettings.saveDirectory)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    private static func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt.string(from: Date())
    }
}
