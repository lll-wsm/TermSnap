import AppKit
import ScreenCaptureKit

class OverlayView: NSView {
    private let screen: NSScreen
    private let windows: [SCWindow]
    private let backgroundImage: NSImage
    private let backgroundCGImage: CGImage

    enum CaptureState {
        case selecting   // Hovering / dragging to define the capture region
        case annotating  // Region confirmed — drawing tools active
    }

    var state: CaptureState = .selecting

    // Use a flipped coordinate system (top-left origin) to match screen coordinates
    // and simplify subview/toolbar positioning.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var isTracking = false
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var darkOverlay: CALayer!
    private var highlightLayer: CAShapeLayer!

    private var hoveredWindow: SCWindow?
    private var hoveredRect: NSRect?

    /// Whether the user actually dragged (>5pt) or just clicked
    private var didDrag = false

    private let annotationView = AnnotationView(frame: .zero)
    private var toolbarView: AnnotationToolbar?
    private var trackingArea: NSTrackingArea?

    // Selection state
    private var selectionResizer: SelectionResizer?
    private var selectedHandle: ResizeHandle?
    private var dragFromPoint: NSPoint?
    private var dragStartRect: NSRect?
    private var dimensionLabel: NSTextField?
    private var handleLayers: [ResizeHandle: CALayer] = [:]

    private var desktopBounds: CGRect {
        NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
    }

    init(frame: NSRect, screen: NSScreen, windows: [SCWindow], backgroundImage: NSImage, backgroundCGImage: CGImage) {
        self.screen = screen
        self.windows = windows
        self.backgroundImage = backgroundImage
        self.backgroundCGImage = backgroundCGImage
        super.init(frame: frame)
        setupLayers()
        setupAnnotationView()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        wantsLayer = true
        layer?.frame = bounds

        let backgroundLayer = CALayer()
        backgroundLayer.frame = bounds
        backgroundLayer.contents = backgroundCGImage
        backgroundLayer.contentsGravity = .resize
        // Ensure background renders correctly on Retina
        backgroundLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(backgroundLayer)

        darkOverlay = CALayer()
        darkOverlay.frame = bounds
        darkOverlay.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.addSublayer(darkOverlay)

        highlightLayer = CAShapeLayer()
        highlightLayer.fillColor = NSColor.clear.cgColor
        highlightLayer.strokeColor = NSColor.systemBlue.cgColor
        highlightLayer.lineWidth = 2.0
        highlightLayer.isHidden = true
        layer?.addSublayer(highlightLayer)
    }

    private func setupAnnotationView() {
        addSubview(annotationView)
        annotationView.isHidden = true
    }

    func startTracking() {
        isTracking = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Selecting State (WeChat-style)

    override func mouseMoved(with event: NSEvent) {
        switch state {
        case .selecting:
            guard isTracking else { return }
            guard startPoint == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let window = findTopmostWindow(at: point) {
                if window.windowID != hoveredWindow?.windowID {
                    hoveredWindow = window
                    let rect = convertFromSCK(window.frame)
                    hoveredRect = rect
                    updateSelection(rect: rect)
                }
            } else {
                // Fallback to full screen if hovering over desktop
                if hoveredWindow != nil || hoveredRect != bounds {
                    hoveredWindow = nil
                    let fullRect = bounds
                    hoveredRect = fullRect
                    updateSelection(rect: fullRect)
                }
            }

        case .annotating:
            let point = convert(event.locationInWindow, from: nil)
            let resizer = SelectionResizer(selectionRect: currentRect)
            resizer.cursorAt(point).set()
        }
    }

    private func updateSelection(rect: NSRect?) {
        guard let rect = rect else {
            highlightLayer.isHidden = true
            darkOverlay.mask = nil
            return
        }

        let path = CGPath(rect: rect, transform: nil)
        highlightLayer.path = path
        highlightLayer.isHidden = false

        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addRect(rect)

        let maskLayer = CAShapeLayer()
        maskLayer.path = maskPath
        maskLayer.fillRule = .evenOdd
        darkOverlay.mask = maskLayer
    }

    // MARK: - Mouse Event Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        switch state {
        case .selecting:
            guard isTracking else { return }
            startPoint = point
            didDrag = false

        case .annotating:
            let resizer = SelectionResizer(selectionRect: currentRect)
            if let handle = resizer.handleAt(point) {
                selectedHandle = handle
                dragFromPoint = point
                dragStartRect = currentRect
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        
        switch state {
        case .selecting:
            guard let start = startPoint else { return }
            let dragRect = NSRect(x: min(start.x, current.x),
                                  y: min(start.y, current.y),
                                  width: abs(current.x - start.x),
                                  height: abs(current.y - start.y))

            if dragRect.width > 5 || dragRect.height > 5 {
                didDrag = true
                hoveredWindow = nil
                hoveredRect = nil
                currentRect = dragRect
                updateSelection(rect: currentRect)
            }

        case .annotating:
            guard let handle = selectedHandle, let from = dragFromPoint, let startRect = dragStartRect else { return }
            let dx = current.x - from.x
            let dy = current.y - from.y
            
            let resizer = SelectionResizer(selectionRect: startRect)
            currentRect = resizer.rectByResizing(startRect, handle: handle, delta: NSPoint(x: dx, y: dy))
            updateSelection(rect: currentRect)
            showHandles(for: currentRect)
            showDimensionLabel(for: currentRect)
            annotationView.frame = currentRect
            repositionToolbar(for: currentRect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch state {
        case .selecting:
            if didDrag && currentRect.width > 5 && currentRect.height > 5 {
                enterAnnotationState(with: currentRect)
            } else if let hRect = hoveredRect {
                enterAnnotationState(with: hRect)
            }
            startPoint = nil
            didDrag = false

        case .annotating:
            selectedHandle = nil
            dragFromPoint = nil
            dragStartRect = nil
        }
    }

    private func findTopmostWindow(at point: NSPoint) -> SCWindow? {
        let sckPoint = convertToSCK(point)
        return windows.first { window in
            window.frame.contains(sckPoint)
        }
    }

    private func convertToSCK(_ point: NSPoint) -> NSPoint {
        // Since both our view and SCK use top-left origin (relative to display),
        // we only need to add the screen origin to get global SCK coordinates.
        let globalX = screen.frame.origin.x + point.x
        // In SCK, Y increases downwards from the top of the primary screen.
        // AppKit global coordinates have Y increasing upwards from primary screen bottom.
        // But our view points are local to this window (screen frame).
        // For SCK, we need global top-left.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appKitGlobalY = screen.frame.origin.y + (screen.frame.height - point.y)
        let sckGlobalY = primaryScreenHeight - appKitGlobalY
        
        return NSPoint(x: globalX, y: sckGlobalY)
    }

    private func convertFromSCK(_ rect: CGRect) -> NSRect {
        // Convert global SCK rect (top-left) to local view rect (top-left, since flipped)
        let localX = rect.origin.x - screen.frame.origin.x
        
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appKitGlobalY = primaryScreenHeight - rect.origin.y
        let localY = screen.frame.height - (appKitGlobalY - screen.frame.origin.y)
        
        return NSRect(x: localX, y: localY, width: rect.width, height: rect.height)
    }

    // MARK: - Annotating State

    private func enterAnnotationState(with rect: NSRect) {
        state = .annotating
        currentRect = rect
        selectionResizer = SelectionResizer(selectionRect: rect)

        updateSelection(rect: rect)
        showHandles(for: rect)
        showDimensionLabel(for: rect)

        annotationView.frame = rect
        annotationView.isHidden = false
        annotationView.pixelatedImage = generatePixelatedImage(for: rect)

        showToolbar(for: rect)
        window?.makeFirstResponder(self)
    }

    private func showHandles(for rect: NSRect) {
        handleLayers.values.forEach { $0.removeFromSuperlayer() }
        handleLayers.removeAll()

        let resizer = SelectionResizer(selectionRect: rect)
        for (handle, handleRect) in resizer.handleRects() {
            let layer = CALayer()
            layer.frame = handleRect
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderColor = NSColor.systemBlue.cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 2
            self.layer?.addSublayer(layer)
            handleLayers[handle] = layer
        }
    }

    private func showDimensionLabel(for rect: NSRect) {
        dimensionLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: "\(Int(rect.width)) × \(Int(rect.height))")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.backgroundColor = NSColor(white: 0, alpha: 0.6)
        label.drawsBackground = true
        label.sizeToFit()

        let labelX = max(4, min(rect.maxX - label.bounds.width + 4, bounds.width - label.bounds.width - 4))
        // Position label above selection if possible, otherwise inside/below
        let labelY = rect.origin.y > 20 ? rect.origin.y - label.bounds.height - 4 : rect.origin.y + 4
        label.setFrameOrigin(NSPoint(x: labelX, y: labelY))
        addSubview(label)
        dimensionLabel = label
    }

    private func showToolbar(for rect: NSRect) {
        toolbarView?.removeFromSuperview()
        let toolbar = AnnotationToolbar(annotationView: annotationView, selectedRect: rect, parentBounds: bounds)
        toolbar.onCopy = { [weak self] in self?.copyToClipboard() }
        toolbar.onSave = { [weak self] in self?.saveToFile() }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        
        addSubview(toolbar)
        toolbarView = toolbar
        repositionToolbar(for: rect)
    }
    
    private func repositionToolbar(for rect: NSRect) {
        guard let toolbar = toolbarView else { return }
        let tw = toolbar.frame.width
        let th = toolbar.frame.height
        let margin: CGFloat = 8
        var tx = rect.midX - tw / 2
        var ty: CGFloat

        let fitsBelow = rect.maxY + th + margin <= bounds.height
        let fitsAbove = rect.origin.y - th - margin >= 0

        if fitsBelow {
            ty = rect.maxY + margin
        } else if fitsAbove {
            ty = rect.origin.y - th - margin
        } else {
            // Not enough space outside — place inside selection at bottom
            ty = rect.maxY - th - margin
        }

        tx = max(margin, min(tx, bounds.width - tw - margin))
        // If toolbar is inside the selection, also clamp horizontally to stay within it
        if !fitsBelow && !fitsAbove {
            tx = max(rect.origin.x + margin, min(tx, rect.maxX - tw - margin))
        }
        toolbar.setFrameOrigin(NSPoint(x: tx, y: ty))
    }

    private var scaleX: CGFloat { CGFloat(backgroundCGImage.width) / bounds.width }
    private var scaleY: CGFloat { CGFloat(backgroundCGImage.height) / bounds.height }

    private func generatePixelatedImage(for cropRect: NSRect) -> CGImage? {
        let sx = scaleX
        let sy = scaleY
        
        // In a flipped view with top-left background image, mapping is 1:1
        let pixelRect = CGRect(x: cropRect.origin.x * sx,
                               y: cropRect.origin.y * sy,
                               width: cropRect.width * sx,
                               height: cropRect.height * sy).integral

        guard let cropped = backgroundCGImage.cropping(to: pixelRect) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(12.0 * sx, forKey: kCIInputScaleKey)

        let context = CIContext()
        guard let output = filter.outputImage,
              let pixellated = context.createCGImage(output, from: output.extent) else { return nil }
        return pixellated
    }

    private func renderFinalImage() -> NSImage? {
        let cropRect = currentRect
        let sx = scaleX
        let sy = scaleY

        let pixelWidth = Int(round(cropRect.width * sx))
        let pixelHeight = Int(round(cropRect.height * sy))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let pixelRect = CGRect(x: cropRect.origin.x * sx,
                               y: cropRect.origin.y * sy,
                               width: CGFloat(pixelWidth),
                               height: CGFloat(pixelHeight)).integral

        guard let cropped = backgroundCGImage.cropping(to: pixelRect) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 1. Draw background (Original context is bottom-left, keeps CGImage upright)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        // 2. Transform for annotations (Top-left origin)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: sx, y: sy)

        for shape in annotationView.shapes {
            shape.draw(in: ctx)
        }
        ctx.restoreGState()

        guard let outputImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: NSSize(width: cropRect.width, height: cropRect.height))
    }

    @objc private func copyToClipboard() {
        guard let image = renderFinalImage() else { return }
        let ow = window as? OverlayWindow
        ExportManager.copyToClipboard(image)
        ow?.deactivate()
    }

    @objc private func saveToFile() {
        guard let image = renderFinalImage() else { return }
        let ow = window as? OverlayWindow
        ow?.orderOut(nil)
        ExportManager.saveToFile(image) { _ in
            ow?.deactivate()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            cancel()
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if state == .annotating {
                copyToClipboard()
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    @objc func cancel() {
        if let ow = window as? OverlayWindow {
            ow.deactivate()
        } else {
            window?.close()
        }
    }
}
