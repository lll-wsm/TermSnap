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

    // MARK: - MosaicShape tests

    @Test func mosaicShapeProperties() {
        let rect = NSRect(x: 10, y: 20, width: 100, height: 80)
        let shape = MosaicShape(rect: rect, pixelatedImage: makeDummyCGImage())
        #expect(shape.rect == rect)
    }

    @Test func mosaicShapeContainsPointInside() {
        let rect = NSRect(x: 10, y: 10, width: 100, height: 100)
        let shape = MosaicShape(rect: rect, pixelatedImage: makeDummyCGImage())
        #expect(shape.contains(NSPoint(x: 50, y: 50)))
    }

    @Test func mosaicShapeDoesNotContainPointOutside() {
        let rect = NSRect(x: 10, y: 10, width: 100, height: 100)
        let shape = MosaicShape(rect: rect, pixelatedImage: makeDummyCGImage())
        #expect(!shape.contains(NSPoint(x: 200, y: 200)))
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
}
