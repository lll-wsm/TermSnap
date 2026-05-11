import AppKit

/// Window for annotating a tall stitched image after scrolling capture.
/// Displays the image in a scrollable view with the standard annotation toolbar.
class StitchedAnnotationWindow: NSWindow {
    private let annotationView = AnnotationView(frame: .zero)
    private var toolbarView: AnnotationToolbar?
    private var scrollView: NSScrollView!
    private var imageView: NSImageView!
    private let stitchedImage: NSImage

    var onDeactivate: (() -> Void)?

    init(image: NSImage, screen: NSScreen) {
        self.stitchedImage = image

        let screenRect = screen.visibleFrame
        
        // Window width: 1:1 with image width, but ensure it fits on screen and fits toolbar (min 850)
        let winWidth = max(850, min(image.size.width, screenRect.width - 40))
        
        // Window height: Image height + Toolbar space (approx 80), up to 90% of screen height
        let winHeight = min(image.size.height + 100, screenRect.height * 0.9)
        
        let winRect = NSRect(x: screenRect.midX - winWidth / 2,
                             y: screenRect.midY - winHeight / 2,
                             width: winWidth, height: winHeight)

        super.init(contentRect: winRect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        self.title = "TermSnap"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isReleasedWhenClosed = false
        self.level = .floating
        self.minSize = NSSize(width: 850, height: 400)

        setupScrollView(with: winRect.size)
        setupToolbar(with: winRect.size)
    }

    private func setupScrollView(with parentSize: NSSize) {
        // Leave 80 pixels at the bottom for the toolbar area
        let toolbarAreaHeight: CGFloat = 80
        scrollView = NSScrollView(frame: NSRect(x: 0, y: toolbarAreaHeight, width: parentSize.width, height: parentSize.height - toolbarAreaHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        imageView = NSImageView(frame: NSRect(origin: .zero, size: stitchedImage.size))
        imageView.image = stitchedImage
        imageView.imageScaling = .scaleNone

        let container = NSView(frame: NSRect(origin: .zero, size: stitchedImage.size))
        container.addSubview(imageView)

        // Annotation view overlays the image exactly
        annotationView.frame = NSRect(origin: .zero, size: stitchedImage.size)
        annotationView.isHidden = false
        container.addSubview(annotationView)

        scrollView.documentView = container
        contentView?.addSubview(scrollView)
    }

    private func setupToolbar(with parentSize: NSSize) {
        let imageRect = NSRect(origin: .zero, size: stitchedImage.size)
        // Ensure parentBounds in toolbar is at least 850 so buttons are not clipped
        let toolbarParentWidth = max(850, parentSize.width)
        let toolbar = AnnotationToolbar(
            annotationView: annotationView,
            selectedRect: imageRect,
            parentBounds: NSRect(x: 0, y: 0, width: toolbarParentWidth, height: parentSize.height)
        )
        toolbar.onCopy = { [weak self] in self?.copyToClipboard() }
        toolbar.onSave = { [weak self] in self?.saveToFile() }
        toolbar.onCancel = { [weak self] in self?.closeWindow() }

        // Manually center the toolbar at the bottom area (outside scrollview)
        let toolbarWidth = toolbar.frame.width
        toolbar.setFrameOrigin(NSPoint(x: (parentSize.width - toolbarWidth) / 2, y: 18))
        
        contentView?.addSubview(toolbar)
        toolbarView = toolbar
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func renderFinalImage() -> NSImage? {
        guard let cgImage = stitchedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Draw base image (bottom-left origin, CGImage draws upright)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Draw annotations (top-left origin transform)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)

        let scale = stitchedImage.size.width > 0 ? CGFloat(pixelWidth) / stitchedImage.size.width : 1.0
        ctx.scaleBy(x: scale, y: scale)

        for shape in annotationView.shapes {
            shape.draw(in: ctx)
        }
        ctx.restoreGState()

        guard let outputImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: stitchedImage.size)
    }

    @objc private func copyToClipboard() {
        guard let image = renderFinalImage() else { return }
        ExportManager.copyToClipboard(image)
        closeWindow()
    }

    @objc private func saveToFile() {
        guard let image = renderFinalImage() else { return }
        orderOut(nil)
        ExportManager.saveToFile(image) { [weak self] _ in
            self?.closeWindow()
        }
    }

    @objc private func closeWindow() {
        orderOut(nil)
        onDeactivate?()
        onDeactivate = nil
    }

    override func close() {
        closeWindow() // red X → full cleanup
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            closeWindow()
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            copyToClipboard()
        } else {
            super.keyDown(with: event)
        }
    }
}
