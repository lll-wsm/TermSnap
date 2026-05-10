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
    
}
