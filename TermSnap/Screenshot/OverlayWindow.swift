import AppKit
import ScreenCaptureKit

class OverlayWindow: NSWindow {
    private let display: SCDisplay
    private let content: SCShareableContent
    private let windows: [SCWindow]
    private weak var captureEngine: CaptureEngine?
    private let mode: CaptureMode
    
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    /// Called when the overlay is dismissed (Esc, Cancel, etc.) so the
    /// owner can release its reference without waiting for willClose.
    var onDeactivate: (() -> Void)?

    init(display: SCDisplay, content: SCShareableContent, windows: [SCWindow], image: NSImage, cgImage: CGImage, captureEngine: CaptureEngine, mode: CaptureMode) {
        self.display = display
        self.content = content
        self.windows = windows
        self.captureEngine = captureEngine
        self.mode = mode

        let screen = NSScreen.screens.first { $0.frame.origin.x == display.frame.origin.x } ?? NSScreen.main!
        let frame = screen.frame

        // Revert to a more standard styleMask for an accessory app to ensure it catches events
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        // Use a level high enough to cover the menu bar (statusBar is 25)
        // but low enough to allow panels and popups if needed.
        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false

        let overlayView = OverlayView(frame: NSRect(origin: .zero, size: frame.size),
                                      screen: screen,
                                      display: display,
                                      windows: windows,
                                      backgroundImage: image,
                                      backgroundCGImage: cgImage,
                                      mode: mode,
                                      captureEngine: captureEngine)

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
        // Global monitor runs on a background queue — dispatch UI work to main.
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                DispatchQueue.main.async { self?.deactivate() }
            }
        }

        // Local monitor: catches Esc when our window is key (runs on main thread)
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.deactivate()
                return nil
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
        ignoresMouseEvents = false
        orderOut(nil)
        onDeactivate?()
        onDeactivate = nil
    }

    /// Let mouse events pass through so the user can scroll content below.
    func enableEventPassthrough() {
        ignoresMouseEvents = true
    }

    func disableEventPassthrough() {
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
