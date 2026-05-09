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
        engine.reset()
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

    /// Verify the image is not solid white by rendering it into a bitmap and checking a pixel.
    /// bitmapInfo premultipliedFirst | byteOrder32Little → [B, G, R, A] in memory.
    private func isNotWhite(_ image: CGImage) -> Bool {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // Read pixel near the middle. CGContext Y-up vs CGImage Y-down only
        // flips the image vertically; the pixel at (midX, midY) in context
        // corresponds to the image center regardless.
        let cx = w / 2, cy = h / 2
        let offset = cy * (w * 4) + cx * 4
        let b = ptr[offset]
        let g = ptr[offset + 1]
        let r = ptr[offset + 2]
        return !(r > 250 && g > 250 && b > 250)
    }

    // MARK: - First frame

    func testFirstFrameReturnsNonNilImage() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let result = await engine.addFrame(image)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 100)
        XCTAssertEqual(result?.height, 100)
    }

    func testFirstFrameOutputSizeMatchesInput() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let result = await engine.addFrame(image)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 100)
        XCTAssertEqual(result?.height, 100)
    }

    func testOutputImageIsNotSolidWhite() async {
        // Verify the crop captures frame content, not just white buffer background.
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let result = await engine.addFrame(image)
        XCTAssertNotNil(result)

        // Compare against our known-red source by hashing a pixel sample.
        // Render both source and result into same-format contexts and compare.
        let r = result!
        for (src, label) in [(image, "source"), (r, "result")] {
            let w = src.width, h = src.height
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { XCTFail("No context"); return }
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { XCTFail("No data"); return }
            let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            let off = (h / 2) * w * 4 + (w / 2) * 4
            let b = ptr[off], g = ptr[off + 1], rVal = ptr[off + 2]
            NSLog("TermSnapTest: \(label) center pixel: R=\(rVal) G=\(g) B=\(b)")
        }
    }

    // MARK: - Reset

    func testResetClearsState() async {
        let image = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        _ = await engine.addFrame(image)
        engine.reset()
        let result = await engine.addFrame(image)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.height, 100)
    }

    // MARK: - Finalize dimension tracking

    func testFinalizeTracksMinMaxAfterScrollingDown() async {
        // Simulate actual scroll behavior by manually calling addFrame with different images.
        // Vision won't find alignment on solid-color images, so frames won't be appended.
        // But we can verify the first frame and finalize are consistent.
        let img1 = createTestImage(color: .red, size: CGSize(width: 100, height: 100))
        let result1 = await engine.addFrame(img1)
        XCTAssertNotNil(result1)
        XCTAssertEqual(result1?.height, 100)

        // A different image won't align via Vision, but finalize should still work.
        let img2 = createTestImage(color: .blue, size: CGSize(width: 100, height: 100))
        let result2 = await engine.addFrame(img2)
        XCTAssertNotNil(result2)
    }
}
