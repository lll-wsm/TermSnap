import ScreenCaptureKit
import AppKit
import CoreMedia

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
    private var currentStream: SCStream?
    private var currentStreamOutput: StreamOutput?

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
                    $0.owningApplication?.bundleIdentifier != "com.apple.dock"
                }
                let (cgImage, nsImage) = try await captureDisplay(display)
                showOverlay(for: display, content: content, windows: windows, image: nsImage, cgImage: cgImage, mode: mode)
                return .started
            }
        } catch {
            NSLog("TermSnap: ScreenCaptureKit error: \(error)")
            return .failed(reason: error.localizedDescription)
        }
    }

    func startStream(display: SCDisplay, area: CGRect, excluding: [NSWindow] = []) async throws -> AsyncStream<CGImage> {
        let output = StreamOutput()
        let stream = AsyncStream<CGImage> { continuation in
            output.continuation = continuation
        }

        // Convert NSWindows to SCWindows for exclusion
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludeSCWindows = content.windows.filter { scWindow in
            excluding.contains { nsWindow in
                scWindow.windowID == CGWindowID(nsWindow.windowNumber)
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludeSCWindows)
        let config = SCStreamConfiguration()
        
        let screen = NSScreen.screens.first { 
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID 
        } ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        
        config.sourceRect = area
        config.width = Int(area.width * scale)
        config.height = Int(area.height * scale)
        config.destinationRect = CGRect(x: 0, y: 0, width: CGFloat(config.width), height: CGFloat(config.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 FPS
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        
        try await scStream.startCapture()
        
        self.currentStream = scStream
        self.currentStreamOutput = output
        
        return stream
    }

    func stopStream() async {
        if let stream = currentStream {
            try? await stream.stopCapture()
            currentStreamOutput?.continuation?.finish()
            currentStream = nil
            currentStreamOutput = nil
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
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                         configuration: config)

        // Size the NSImage at the screen's point dimensions so the backing scale is implicit
        let pointSize = screen.frame.size
        return (image, NSImage(cgImage: image, size: pointSize))
    }

    private func showOverlay(for display: SCDisplay, content: SCShareableContent, windows: [SCWindow], image: NSImage, cgImage: CGImage, mode: CaptureMode) {
        let window = OverlayWindow(display: display, content: content, windows: windows, image: image, cgImage: cgImage, captureEngine: self, mode: mode)
        overlayWindow = window
        window.onDeactivate = { [weak self] in
            self?.overlayWindow = nil
        }
        window.show()
    }
}

class StreamOutput: NSObject, SCStreamDelegate, SCStreamOutput {
    var continuation: AsyncStream<CGImage>.Continuation?
    private let ciContext = CIContext()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        continuation?.yield(cgImage)
    }
}
