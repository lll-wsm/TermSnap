import AppKit

protocol AnnotationShape {
    var color: NSColor { get set }
    var lineWidth: CGFloat { get set }
    func draw(in context: CGContext)
    func contains(_ point: NSPoint) -> Bool
}

struct ArrowShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var startPoint: NSPoint
    var endPoint: NSPoint

    func draw(in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()

        let headLength: CGFloat = 14
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headAngle: CGFloat = .pi / 6

        context.move(to: endPoint)
        context.addLine(to: CGPoint(x: endPoint.x - headLength * cos(angle - headAngle),
                                    y: endPoint.y - headLength * sin(angle - headAngle)))
        context.move(to: endPoint)
        context.addLine(to: CGPoint(x: endPoint.x - headLength * cos(angle + headAngle),
                                    y: endPoint.y - headLength * sin(angle + headAngle)))
        context.strokePath()
    }

    func contains(_ point: NSPoint) -> Bool {
        let dist = distanceFromPoint(toLine: (startPoint, endPoint), point: point)
        return dist < lineWidth + 5
    }
}

struct RectShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var rect: NSRect

    func draw(in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }

    func contains(_ point: NSPoint) -> Bool {
        return rect.insetBy(dx: -lineWidth - 5, dy: -lineWidth - 5).contains(point)
    }
}

struct TextShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var text: String
    var origin: NSPoint

    private var fontSize: CGFloat { 14 + lineWidth * 2 }

    func draw(in context: CGContext) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color
        ]
        let str = NSAttributedString(string: text, attributes: attr)
        let line = CTLineCreateWithAttributedString(str)

        context.saveGState()
        // AnnotationView uses a flipped coordinate system (isFlipped = true).
        // CTLineDraw draws with the current CTM, so in a flipped context the
        // glyphs render upside-down. Flip the text matrix to compensate.
        var textMatrix = CGAffineTransform(translationX: origin.x, y: origin.y + fontSize)
        textMatrix = textMatrix.scaledBy(x: 1, y: -1)
        context.textMatrix = textMatrix
        CTLineDraw(line, context)
        context.restoreGState()
    }

    func contains(_ point: NSPoint) -> Bool {
        let approxWidth = CGFloat(text.count) * fontSize * 0.6
        let boundingRect = NSRect(x: origin.x, y: origin.y,
                                  width: approxWidth, height: fontSize * 1.2)
        return boundingRect.contains(point)
    }
}

struct PenShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var points: [NSPoint]

    func draw(in context: CGContext) {
        guard points.count > 1 else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: points[0])
        for i in 1..<points.count {
            context.addLine(to: points[i])
        }
        context.strokePath()
    }

    func contains(_ point: NSPoint) -> Bool {
        for i in 0..<(points.count - 1) {
            if distanceFromPoint(toLine: (points[i], points[i + 1]), point: point) < lineWidth + 5 {
                return true
            }
        }
        return false
    }
}

struct EllipseShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var rect: NSRect

    func draw(in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
    }

    func contains(_ point: NSPoint) -> Bool {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let dx = (point.x - cx) / rx, dy = (point.y - cy) / ry
        return (dx * dx + dy * dy) <= 1.0
    }
}

struct LineShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var startPoint: NSPoint
    var endPoint: NSPoint

    func draw(in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()
    }

    func contains(_ point: NSPoint) -> Bool {
        let dist = distanceFromPoint(toLine: (startPoint, endPoint), point: point)
        return dist < lineWidth + 5
    }
}

// MosaicShape ignores color/lineWidth — it renders pixelatedImage clipped to rect.
class MosaicShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    let rect: NSRect
    let pixelatedImage: CGImage

    init(rect: NSRect, pixelatedImage: CGImage) {
        self.color = .clear
        self.lineWidth = 0
        self.rect = rect
        self.pixelatedImage = pixelatedImage
    }

    func draw(in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.draw(pixelatedImage, in: rect)
        context.restoreGState()
    }

    func contains(_ point: NSPoint) -> Bool {
        rect.contains(point)
    }
}

private func distanceFromPoint(toLine line: (NSPoint, NSPoint), point: NSPoint) -> CGFloat {
    let a = line.0
    let b = line.1
    let ab = NSPoint(x: b.x - a.x, y: b.y - a.y)
    let ap = NSPoint(x: point.x - a.x, y: point.y - a.y)
    let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / (ab.x * ab.x + ab.y * ab.y)))
    let projection = NSPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    let dx = point.x - projection.x
    let dy = point.y - projection.y
    return sqrt(dx * dx + dy * dy)
}
