import AppKit

class AnnotationView: NSView, NSTextFieldDelegate {
    var shapes: [AnnotationShape] = []
    var undoStack: [AnnotationShape] = []

    var currentTool: AnnotationTool = .arrow
    var currentColor: NSColor = .red
    var currentLineWidth: CGFloat = 3

    private var dragStart: NSPoint?
    private var currentPenPoints: [NSPoint] = []
    private var tempShape: AnnotationShape?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        for shape in shapes {
            shape.draw(in: ctx)
        }

        if let temp = tempShape {
            temp.draw(in: ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point

        if currentTool == .pen {
            currentPenPoints = [point]
        } else if currentTool == .text {
            addTextShape(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)

        switch currentTool {
        case .arrow:
            tempShape = ArrowShape(color: currentColor, lineWidth: currentLineWidth,
                                   startPoint: start, endPoint: current)
        case .rect:
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            tempShape = RectShape(color: currentColor, lineWidth: currentLineWidth, rect: rect)
        case .ellipse:
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            tempShape = EllipseShape(color: currentColor, lineWidth: currentLineWidth, rect: rect)
        case .line:
            tempShape = LineShape(color: currentColor, lineWidth: currentLineWidth,
                                  startPoint: start, endPoint: current)
        case .pen:
            currentPenPoints.append(current)
            tempShape = PenShape(color: currentColor, lineWidth: currentLineWidth, points: currentPenPoints)
        case .text:
            break
        case .mosaic:
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            if rect.width > 5 && rect.height > 5, let pixImg = pixelatedImage {
                tempShape = MosaicShape(rect: rect, pixelatedImage: pixImg)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let temp = tempShape {
            shapes.append(temp)
            undoStack = []
            tempShape = nil
        }
        dragStart = nil
        currentPenPoints = []
        needsDisplay = true
    }

    private func addTextShape(at point: NSPoint) {
        let fontSize = 14 + currentLineWidth * 2
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = font.boundingRectForFont.height

        // Wrap NSTextField in a container so text renders correctly
        // inside our flipped (top-left origin) view.
        let container = NSView(frame: NSRect(x: point.x, y: point.y, width: 60, height: lineHeight + 6))
        container.wantsLayer = true

        let field = NSTextField(frame: NSRect(x: 3, y: 0, width: 54, height: lineHeight + 6))
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = currentColor
        field.font = font
        field.placeholderString = ""
        field.isEditable = true
        field.delegate = self
        field.tag = textFields.count
        field.sizeToFit()

        container.addSubview(field)
        addSubview(container)
        field.becomeFirstResponder()

        textFields.append((field: field, container: container, point: point))
    }

    private var textFields: [(field: NSTextField, container: NSView, point: NSPoint)] = []

    /// Pixelated version of the captured area, used by MosaicShape for rendering.
    /// Set by OverlayView when entering annotation state.
    var pixelatedImage: CGImage?

    /// Capso-style flipped coordinate system (top-left origin) ensures
    /// convert() and draw(_:) use the same coordinate space.
    override var isFlipped: Bool { true }

    func undo() {
        guard let last = shapes.popLast() else { return }
        undoStack.append(last)
        needsDisplay = true
    }

    func redo() {
        guard let shape = undoStack.popLast() else { return }
        shapes.append(shape)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let index = textFields.firstIndex(where: { $0.field === field })
        else { return }

        let entry = textFields[index]
        if !field.stringValue.isEmpty {
            let shape = TextShape(color: currentColor, lineWidth: currentLineWidth,
                                  text: field.stringValue, origin: entry.point)
            shapes.append(shape)
            undoStack = []
        }
        entry.container.removeFromSuperview()
        textFields.remove(at: index)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let index = textFields.firstIndex(where: { $0.field === field })
        else { return }

        let entry = textFields[index]
        let fontSize = 14 + currentLineWidth * 2
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = font.boundingRectForFont.height
        let padding: CGFloat = 6

        let textWidth = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        let newFieldWidth = max(40, textWidth + padding)
        let newContainerWidth = newFieldWidth + padding

        field.setFrameSize(NSSize(width: newFieldWidth, height: lineHeight + padding))
        entry.container.setFrameSize(NSSize(width: newContainerWidth, height: lineHeight + padding))
    }
}
