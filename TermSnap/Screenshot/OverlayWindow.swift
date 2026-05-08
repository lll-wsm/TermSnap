import AppKit
import ScreenCaptureKit

class OverlayWindow: NSWindow {
    private let display: SCDisplay
    private let content: SCShareableContent
    private let windows: [SCWindow]
    private weak var captureEngine: CaptureEngine?
    
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    /// Called when the overlay is dismissed (Esc, Cancel, etc.) so the
    /// owner can release its reference without waiting for willClose.
    var onDeactivate: (() -> Void)?

    init(display: SCDisplay, content: SCShareableContent, windows: [SCWindow], image: NSImage, cgImage: CGImage, captureEngine: CaptureEngine) {
        self.display = display
        self.content = content
        self.windows = windows
        self.captureEngine = captureEngine

        let screen = NSScreen.screens.first { $0.frame.origin.x == display.frame.origin.x } ?? NSScreen.main!
        let frame = screen.frame

        // Revert to a more standard styleMask for an accessory app to ensure it catches events
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        // Using a high level but not .screenSaver which can be problematic with event routing
        self.level = NSWindow.Level(Int(CGWindowLevelForKey(.maximumWindow)))
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false

        let overlayView = OverlayView(frame: NSRect(origin: .zero, size: frame.size),
                                      screen: screen,
                                      windows: windows,
                                      backgroundImage: image,
                                      backgroundCGImage: cgImage)

        self.contentView = overlayView
    }

    func show() {
        // Critical: Ensure the app and window can receive events
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        
        installEscMonitor()
        
        if let overlayView = contentView as? OverlayView {
            overlayView.startTracking()
            makeFirstResponder(overlayView)
        }
    }

    deinit {
        removeEscMonitor()
    }

    // MARK: - Esc Monitoring (Safety First)

    private func installEscMonitor() {
        // Global monitor: catches ESC even when window is not key (Critical Safety)
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                NSLog("TermSnap: Global Esc caught")
                self?.deactivate()
            }
        }
        
        // Local monitor: catches ESC when our window is key
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                NSLog("TermSnap: Local Esc caught")
                self?.deactivate()
                return nil // swallow event
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let monitor = globalEscMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscMonitor = nil
        }
        if let monitor = localEscMonitor {
            NSEvent.removeMonitor(monitor)
            localEscMonitor = nil
        }
    }

    func deactivate() {
        removeEscMonitor()
        orderOut(nil)
        onDeactivate?()
        onDeactivate = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
