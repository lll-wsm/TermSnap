import AppKit

class AnnotationView: NSView, NSTextFieldDelegate {
    var shapes: [AnnotationShape] = []
    var undoStack: [AnnotationShape] = []

    var currentTool: AnnotationTool = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    var currentColor: NSColor = .red {
        didSet {
            for entry in textFields {
                entry.field.textColor = currentColor
            }
        }
    }
    var currentLineWidth: CGFloat = 2 {
        didSet {
            for entry in textFields {
                let fontSize = 14 + currentLineWidth * 2
                let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                entry.field.font = font
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: entry.field, userInfo: nil))
            }
        }
    }

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

        if !textFields.isEmpty {
            var clickedInside = false
            for entry in textFields {
                if entry.container.frame.contains(point) {
                    clickedInside = true
                    break
                }
            }
            if !clickedInside {
                window?.makeFirstResponder(self)
                return
            }
        }

        if currentTool == .pen || currentTool == .eraser {
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
        case .eraser:
            currentPenPoints.append(current)
            if let blurImg = blurredImage {
                tempShape = EraserShape(color: currentColor, lineWidth: currentLineWidth * 5 + 10,
                                        points: currentPenPoints, blurredImage: blurImg,
                                        canvasSize: bounds.size)
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
        field.usesSingleLineMode = false
        field.cell?.isScrollable = false
        field.cell?.wraps = true
        field.sizeToFit()

        container.addSubview(field)
        addSubview(container)
        field.becomeFirstResponder()

        textFields.append((field: field, container: container, point: point))
    }

    private var textFields: [(field: NSTextField, container: NSView, point: NSPoint)] = []

    /// Blurred version of the captured area, used by EraserShape for rendering.
    /// Set by OverlayView when entering annotation state.
    var blurredImage: CGImage?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if currentTool == .eraser {
            addCursorRect(bounds, cursor: NSCursor.eraser)
        }
    }

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

    func commitActiveTextFields() {
        if !textFields.isEmpty {
            window?.makeFirstResponder(self)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewline(nil)
            return true
        }
        return false
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

        let text: String
        if let editor = field.currentEditor() {
            text = editor.string
        } else {
            text = field.stringValue
        }

        let lines = text.components(separatedBy: .newlines)
        var maxLineWidth: CGFloat = 0
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            if width > maxLineWidth {
                maxLineWidth = width
            }
        }

        let newFieldWidth = max(40, maxLineWidth + padding)
        let newContainerWidth = newFieldWidth + padding
        let lineCount = max(1, lines.count)
        let totalHeight = CGFloat(lineCount) * lineHeight

        field.setFrameSize(NSSize(width: newFieldWidth, height: totalHeight + padding))
        entry.container.setFrameSize(NSSize(width: newContainerWidth, height: totalHeight + padding))
    }
}

extension NSCursor {
    static var eraser: NSCursor {
        if let image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil) {
            let size = NSSize(width: 24, height: 24)
            let resizedImage = NSImage(size: size)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            resizedImage.unlockFocus()
            // The SF Symbol "eraser" tip is at the bottom-left corner of the image,
            // which corresponds to coordinate (2, 22) in top-left-based Cocoa cursor space.
            return NSCursor(image: resizedImage, hotSpot: NSPoint(x: 2, y: 22))
        }
        return .crosshair
    }
}
