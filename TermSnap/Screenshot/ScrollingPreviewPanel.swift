import AppKit
import CoreGraphics

class ScrollingPreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private let rawImageView = NSImageView()
    private let containerView = NSView()
    private let scrollView = NSScrollView()
    private let debugLabel = NSTextField()
    
    init(screen: NSScreen) {
        let width: CGFloat = 140
        let maxHeight: CGFloat = 400
        let rect = NSRect(x: 0, y: 0, width: width, height: maxHeight)
        
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        
        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        setupUI()
        positionInCorner(of: screen)
    }
    
    private func setupUI() {
        containerView.frame = contentView!.bounds
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.masksToBounds = true
        contentView = containerView
        
        scrollView.frame = containerView.bounds
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        containerView.addSubview(scrollView)
        
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scrollView.documentView = imageView

        rawImageView.frame = NSRect(x: 100, y: 5, width: 35, height: 35)
        rawImageView.imageScaling = .scaleProportionallyUpOrDown
        rawImageView.wantsLayer = true
        rawImageView.layer?.borderColor = NSColor.green.cgColor
        rawImageView.layer?.borderWidth = 1
        containerView.addSubview(rawImageView)

        debugLabel.isEditable = false
        debugLabel.isBordered = false
        debugLabel.drawsBackground = true
        debugLabel.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        debugLabel.textColor = .green
        debugLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        debugLabel.stringValue = "F:0|H:0|dy:0"
        debugLabel.frame = NSRect(x: 5, y: 5, width: 90, height: 28)
        debugLabel.maximumNumberOfLines = 2
        containerView.addSubview(debugLabel)

        let hintLabel = NSTextField(labelWithString: "Enter ↵")
        hintLabel.alignment = .center
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        hintLabel.frame = NSRect(x: 55, y: 5, width: 30, height: 18)
        containerView.addSubview(hintLabel)
    }
    
    private func positionInCorner(of screen: NSScreen) {
        let screenRect = screen.visibleFrame
        let padding: CGFloat = 20
        let panelX = screenRect.maxX - frame.width - padding
        let panelY = screenRect.minY + padding
        self.setFrameOrigin(NSPoint(x: panelX, y: panelY))
    }
    
    func updatePosition(relativeTo captureRect: NSRect, on screen: NSScreen) {
        let screenRect = screen.frame
        let padding: CGFloat = 10
        
        var panelX = captureRect.maxX + padding
        if panelX + frame.width > screenRect.maxX - padding {
            panelX = captureRect.maxX - frame.width - padding
        }
        
        let panelY = captureRect.midY - frame.height / 2
        let visible = screen.visibleFrame
        let clampedY = max(visible.minY + padding, min(panelY, visible.maxY - frame.height - padding))
        let clampedX = max(visible.minX + padding, min(panelX, visible.maxX - frame.width - padding))
        
        self.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }
    
    func updateImage(_ image: CGImage, lastDy: Double, frameCount: Int, area: CGRect, rawFrame: CGImage? = nil) {
        let nsImage = NSImage(cgImage: image, size: .zero)
        let totalH = image.height
        
        let width = scrollView.bounds.width
        let aspectRatio = CGFloat(image.height) / CGFloat(image.width)
        let height = width * aspectRatio
        
        DispatchQueue.main.async {
            let dyString = String(format: "%.2f", lastDy)
            let areaString = "R:\(Int(area.origin.x)),\(Int(area.origin.y)) \(Int(area.width))x\(Int(area.height))"
            self.debugLabel.stringValue = "F:\(frameCount) H:\(totalH) dy:\(dyString)\n\(areaString)"
            
            self.imageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            self.imageView.image = nsImage
            
            if let raw = rawFrame {
                self.rawImageView.image = NSImage(cgImage: raw, size: .zero)
            }
            
            if let documentView = self.scrollView.documentView {
                documentView.scroll(NSPoint(x: 0, y: 0))
            }
        }
    }
}
