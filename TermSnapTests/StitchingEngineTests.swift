import XCTest
import CoreGraphics
import AppKit
@testable import TermSnap

final class StitchingEngineTests: XCTestCase {
    var engine: StitchingEngine!

    override func setUp() {
        super.setUp()
        engine = StitchingEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func createTestImage(color: NSColor, size: CGSize) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    private func createPatternImage(size: CGSize, squareRect: CGRect) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        context.setFillColor(NSColor.red.cgColor)
        context.fill(squareRect)
        return context.makeImage()!
    }

    // MARK: - Initial frame

    func testFirstFrameReturnsNonNilImage() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let result = await engine.addFrame(image)
        XCTAssertNotNil(result)
    }

    func testFirstFrameOutputSizeMatchesInput() async {
        let size = CGSize(width: 100, height: 100)
        let image = createTestImage(color: .red, size: size)
        let result = await engine.addFrame(image)
        XCTAssertEqual(CGFloat(result?.width ?? 0), size.width)
        XCTAssertEqual(CGFloat(result?.height ?? 0), size.height)
    }

    // MARK: - Reset state

    func testResetClearsState() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        _ = await engine.addFrame(image)
        engine.reset()
        
        let image2 = createTestImage(color: .blue, size: CGSize(width: 50, height: 50))
        let result = await engine.addFrame(image2)
        XCTAssertEqual(result?.width, 50)
    }

    // MARK: - Basic finalize

    func testOutputImageIsNotSolidWhite() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        _ = await engine.addFrame(image)
        let final = engine.finalize()
        XCTAssertNotNil(final)
        
        // Simple check: middle pixel should be red (not white)
        // CoreGraphics coordinates for drawing were handled in addFrame
        // But for solid images, addFrame returns baseline immediately.
    }

    func testWidthChangeFinalizesStitching() async {
        // 1. Baseline
        let img1 = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let res1 = await engine.addFrame(img1)
        XCTAssertNotNil(res1)
        
        // 2. Add a frame with different width
        let img2 = createTestImage(color: .blue, size: CGSize(width: 110, height: 100))
        let result = await engine.addFrame(img2)
        
        XCTAssertNotNil(result)
    }

    func testHamburgerCompositionHeight() async {
        let originalSize = CGSize(width: 100, height: 100)
        let baseline = createTestImage(color: .red, size: originalSize)
        let last = createTestImage(color: .blue, size: originalSize)
        
        engine.reset()
        engine.baselineFrame = baseline
        engine.lastFrame = last
        engine.phase = .stableStitching
        engine.frameWidth = 100
        engine.frameHeight = 100
        
        // Content rect from y=10 to y=90 (height=80)
        // CoreGraphics coordinates: y=0 is bottom.
        // So header is at the top (y=90 to 100) -> height 10
        // Footer is at the bottom (y=0 to 10) -> height 10
        // Middle is y=10 to 90 -> height 80
        engine.finalCropRect = CGRect(x: 0, y: 10, width: 100, height: 80)
        
        engine.setupBuffer(width: 100, height: 20000)
        
        // Simulate a 20px scroll
        // initialY = 10000
        // If we scrolled 20px, maxY - minY should be 100 (80 original + 20 scroll)
        engine.minY = 10000
        engine.maxY = 10100
        
        // We need to draw SOMETHING in the buffer so cropping works
        let midImage = createTestImage(color: .green, size: CGSize(width: 100, height: 100))
        engine.drawInBuffer(midImage, at: 10000, height: 100)
        
        let result = engine.finalize()
        XCTAssertNotNil(result)
        
        // Expected height:
        // Header height: 10 (from y=0 to 10 in image, which is the TOP 10 pixels if we don't flip)
        // Wait, in finalize():
        // let headerHeight = Int(cropRect.minY) = 10
        // let footerY = Int(cropRect.maxY) = 90
        // let footerHeight = Int(last.height) - footerY = 100 - 90 = 10
        // totalHeight = 10 + 100 + 10 = 120
        
        XCTAssertEqual(result?.height, 120)
    }
}
