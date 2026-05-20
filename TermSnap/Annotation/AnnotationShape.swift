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
    
    private var font: NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: .bold)
    }

    func draw(in context: CGContext) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        
        let lines = text.components(separatedBy: .newlines)
        let lineHeight = font.boundingRectForFont.height

        context.saveGState()
        for (index, lineText) in lines.enumerated() {
            let str = NSAttributedString(string: lineText, attributes: attr)
            let line = CTLineCreateWithAttributedString(str)
            let lineYOffset = CGFloat(index) * lineHeight
            
            // AnnotationView uses a flipped coordinate system (isFlipped = true).
            // CTLineDraw draws with the current CTM, so in a flipped context the
            // glyphs render upside-down. Flip the text matrix to compensate.
            var textMatrix = CGAffineTransform(translationX: origin.x, y: origin.y + fontSize + lineYOffset)
            textMatrix = textMatrix.scaledBy(x: 1, y: -1)
            context.textMatrix = textMatrix
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    func contains(_ point: NSPoint) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let lineHeight = font.boundingRectForFont.height
        
        var maxApproxWidth: CGFloat = 0
        for lineText in lines {
            let approxWidth = CGFloat(lineText.count) * fontSize * 0.6
            if approxWidth > maxApproxWidth {
                maxApproxWidth = approxWidth
            }
        }
        
        let totalHeight = CGFloat(lines.count) * lineHeight
        let boundingRect = NSRect(x: origin.x, y: origin.y,
                                  width: maxApproxWidth, height: totalHeight)
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

// EraserShape applies Gaussian blur clipped to a freehand path.
struct EraserShape: AnnotationShape {
    var color: NSColor
    var lineWidth: CGFloat
    var points: [NSPoint]
    let blurredImage: CGImage
    let canvasSize: NSSize

    func draw(in context: CGContext) {
        guard points.count > 0 else { return }
        context.saveGState()

        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<points.count {
            path.addLine(to: points[i])
        }

        context.addPath(path)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        context.replacePathWithStrokedPath()
        context.clip()

        let rect = CGRect(origin: .zero, size: canvasSize)
        context.draw(blurredImage, in: rect)
        
        context.restoreGState()
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
