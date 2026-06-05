import Testing
import AppKit
@testable import TermSnap

struct AnnotationShapeTests {
    /// Creates a minimal 1x1 white CGImage for testing MosaicShape.
    private func makeDummyCGImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }


    @Test func ellipseShapeProperties() {
        let shape = EllipseShape(color: .red, lineWidth: 3, rect: NSRect(x: 0, y: 0, width: 100, height: 50))
        #expect(shape.color == .red)
        #expect(shape.lineWidth == 3)
        #expect(shape.rect.width == 100)
    }

    @Test func ellipseShapeContainsPointInside() {
        let shape = EllipseShape(color: .red, lineWidth: 3, rect: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(shape.contains(NSPoint(x: 50, y: 50)))
    }

    @Test func ellipseShapeDoesNotContainPointFarOutside() {
        let shape = EllipseShape(color: .red, lineWidth: 3, rect: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!shape.contains(NSPoint(x: 200, y: 200)))
    }

    @Test func lineShapeProperties() {
        let shape = LineShape(color: .blue, lineWidth: 2, startPoint: .zero, endPoint: NSPoint(x: 100, y: 100))
        #expect(shape.color == .blue)
        #expect(shape.endPoint.x == 100)
    }

    @Test func lineShapeContainsPointNearLine() {
        let shape = LineShape(color: .blue, lineWidth: 4, startPoint: .zero, endPoint: NSPoint(x: 100, y: 0))
        #expect(shape.contains(NSPoint(x: 50, y: 5)))
    }

    @Test func lineShapeDoesNotContainPointFarFromLine() {
        let shape = LineShape(color: .blue, lineWidth: 4, startPoint: .zero, endPoint: NSPoint(x: 100, y: 0))
        #expect(!shape.contains(NSPoint(x: 50, y: 50)))
    }

    // MARK: - EraserShape tests

    @Test func eraserShapeProperties() {
        let size = NSSize(width: 200, height: 150)
        let points = [NSPoint(x: 10, y: 10), NSPoint(x: 50, y: 50)]
        let shape = EraserShape(color: .clear, lineWidth: 20, points: points, blurredImage: makeDummyCGImage(), canvasSize: size)
        #expect(shape.lineWidth == 20)
        #expect(shape.points.count == 2)
        #expect(shape.canvasSize == size)
    }

    @Test func eraserShapeContainsPointNearStroke() {
        let size = NSSize(width: 200, height: 150)
        let points = [NSPoint(x: 10, y: 10), NSPoint(x: 100, y: 10)]
        let shape = EraserShape(color: .clear, lineWidth: 20, points: points, blurredImage: makeDummyCGImage(), canvasSize: size)
        #expect(shape.contains(NSPoint(x: 50, y: 10)))
        #expect(shape.contains(NSPoint(x: 50, y: 15)))
        #expect(!shape.contains(NSPoint(x: 50, y: 50)))
    }

    // MARK: - Edge-case hit testing tests

    @Test func ellipseShapeContainsPointOnBoundary() {
        let shape = EllipseShape(color: .red, lineWidth: 3, rect: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(shape.contains(NSPoint(x: 50, y: 50))) // center of circle
    }

    @Test func lineShapeContainsPointAtEndpoint() {
        let shape = LineShape(color: .blue, lineWidth: 4, startPoint: .zero, endPoint: NSPoint(x: 100, y: 0))
        #expect(shape.contains(NSPoint(x: 0, y: 0))) // at start point
    }

    @Test func lineShapeWithZeroLengthDoesNotCrash() {
        let shape = LineShape(color: .blue, lineWidth: 4, startPoint: NSPoint(x: 50, y: 50), endPoint: NSPoint(x: 50, y: 50))
        #expect(!shape.contains(NSPoint(x: 50, y: 60))) // zero-length line, should not crash
    }

    // MARK: - TextShape tests

    @Test func textShapeProperties() {
        let shape = TextShape(color: .green, lineWidth: 3, text: "Hello", origin: NSPoint(x: 10, y: 20))
        #expect(shape.color == .green)
        #expect(shape.lineWidth == 3)
        #expect(shape.text == "Hello")
        #expect(shape.origin.x == 10)
    }

    @Test func textShapeContainsPoint() {
        let shape = TextShape(color: .green, lineWidth: 2, text: "Hello", origin: NSPoint(x: 10, y: 20))
        #expect(shape.contains(NSPoint(x: 15, y: 25)))
        #expect(!shape.contains(NSPoint(x: 100, y: 100)))
    }

    @Test func textShapeMultilineContainsPoint() {
        let shape = TextShape(color: .green, lineWidth: 2, text: "Line 1\nLonger Line 2\n3", origin: NSPoint(x: 10, y: 20))
        #expect(shape.contains(NSPoint(x: 15, y: 25)))
        #expect(shape.contains(NSPoint(x: 15, y: 45)))
        #expect(!shape.contains(NSPoint(x: 200, y: 45)))
        #expect(!shape.contains(NSPoint(x: 15, y: 150)))
    }
}
