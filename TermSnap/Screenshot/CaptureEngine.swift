import ScreenCaptureKit
import AppKit

enum CaptureMode {
    case interactive
}

enum CaptureStartResult {
    case started
    case permissionDenied
    case failed(reason: String)
}

@MainActor
class CaptureEngine {
    private var overlayWindow: OverlayWindow?

    func capture(_ mode: CaptureMode) async -> CaptureStartResult {
        guard CaptureEngine.ensureScreenCapturePermission() else {
            return .permissionDenied
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true,
                                                                               onScreenWindowsOnly: true)
            switch mode {
            case .interactive:
                guard let display = content.displays.first else {
                    return .failed(reason: "No available display was found for capture.")
                }
                let windows = content.windows.filter { 
                    $0.isOnScreen && 
                    $0.windowLayer == 0 &&
                    !($0.title ?? "").isEmpty &&
                    $0.frame.width > 10 && 
                    $0.frame.height > 10 &&
                    $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                    $0.owningApplication?.bundleIdentifier != "com.apple.dock"
                }
                let (cgImage, nsImage) = try await captureDisplay(display)
                showOverlay(for: display, content: content, windows: windows, image: nsImage, cgImage: cgImage)
                return .started
            }
        } catch {
            NSLog("TermSnap: ScreenCaptureKit error: \(error)")
            return .failed(reason: error.localizedDescription)
        }
    }

    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func ensureScreenCapturePermission() -> Bool {
        hasScreenCapturePermission() || CGRequestScreenCaptureAccess()
    }

    private func captureDisplay(_ display: SCDisplay) async throws -> (cgImage: CGImage, nsImage: NSImage) {
        let filter = SCContentFilter(display: display,
                                     excludingWindows: [])
        let config = SCStreamConfiguration()

        // SCDisplay.width/height are in points; SCStreamConfiguration expects pixels.
        // Multiply by backing scale factor so Retina displays capture at full resolution.
        let screen = NSScreen.screens.first { $0.frame.origin.x == display.frame.origin.x } ?? NSScreen.main!
        let backingScale = screen.backingScaleFactor
        config.width = Int(Double(display.width) * backingScale)
        config.height = Int(Double(display.height) * backingScale)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Hide cursor before capture so it doesn't appear in the screenshot
        CGDisplayHideCursor(CGMainDisplayID())

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                         configuration: config)

        CGDisplayShowCursor(CGMainDisplayID())

        // Size the NSImage at the screen's point dimensions so the backing scale is implicit
        let pointSize = screen.frame.size
        return (image, NSImage(cgImage: image, size: pointSize))
    }

    private func showOverlay(for display: SCDisplay, content: SCShareableContent, windows: [SCWindow], image: NSImage, cgImage: CGImage) {
        let window = OverlayWindow(display: display, content: content, windows: windows, image: image, cgImage: cgImage, captureEngine: self)
        overlayWindow = window
        window.onDeactivate = { [weak self] in
            self?.overlayWindow = nil
        }
        window.show()
    }
}
