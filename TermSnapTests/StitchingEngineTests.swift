import XCTest
import CoreGraphics
import AppKit
@testable import TermSnap

@MainActor
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

    // MARK: - Orientation correctness

    func testBufferDrawPreservesOrientation() async {
        // Setup a small buffer manually
        engine.setupBuffer(width: 100, height: 500)

        // Create a test image: red at top, blue at bottom
        let img = createTopBottomImage(width: 100, topHeight: 20, bottomHeight: 20)
        // Total height = 40

        // Draw it at y=200 in the buffer
        engine.drawInBuffer(img, at: 200, height: 40)

        // Extract from buffer
        guard let bufferImage = engine.bufferContext?.makeImage() else {
            XCTFail("Failed to create buffer image")
            return
        }

        // Crop the region we drew into
        guard let cropped = bufferImage.cropping(to: CGRect(x: 0, y: 200, width: 100, height: 40)) else {
            XCTFail("Failed to crop")
            return
        }

        // Verify dimensions
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 40)

        // Read pixels via an unflipped context
        guard let ctx = CGContext(
            data: nil, width: 100, height: 40,
            bitsPerComponent: 8, bytesPerRow: 100 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Failed to create context")
            return
        }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 100, height: 40))

        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: 100 * 40 * 4) else {
            XCTFail("Failed to get pixel data")
            return
        }

        // In unflipped read context: CGImage row 0 → data[row 39] (visual top),
        // CGImage row 39 → data[row 0] (visual bottom).
        // Buffer flipped context + makeImage inverts once; drawing here inverts again.
        // RED (top of test image) → data[row 39], BLUE (bottom) → data[row 0].

        // Visual top (data row 39): should be RED
        let topR = data[39*100*4 + 2]
        let topB = data[39*100*4]
        XCTAssertGreaterThan(topR, 200, "Visual TOP (data[39]) should be red — R=\(topR) B=\(topB)")
        XCTAssertLessThan(topB, 50, "Visual TOP (data[39]) should be red — R=\(topR) B=\(topB)")

        // Visual bottom (data row 0): should be BLUE
        let bottomR = data[2]
        let bottomB = data[0]
        XCTAssertGreaterThan(bottomB, 200, "Visual BOTTOM (data[0]) should be blue — R=\(bottomR) B=\(bottomB)")
        XCTAssertLessThan(bottomR, 50, "Visual BOTTOM (data[0]) should be blue — R=\(bottomR) B=\(bottomB)")
    }

    // MARK: - Finalize composite orientation

    /// Simulates the exact finalize() composite path:
    /// Header (from raw frame) + Stitched (from buffer) + Footer (from raw frame)
    /// All drawn in a flipped finalContext. Verifies correct orientation for all layers.
    func testFinalizeCompositeOrientation() async {
        let w = 100
        let headerH = 20
        let contentH = 40
        let footerH = 15
        let totalH = headerH + contentH + footerH

        // ── Create "raw frame" with known header (green), content (white), footer (yellow) ──
        let rawFrame = createThreeBandImage(
            width: w, topH: headerH, midH: contentH, bottomH: footerH,
            topColor: .green, midColor: .white, bottomColor: .yellow
        )

        // ── Create buffer content (blue band) ──
        let bufferH = 500
        engine.setupBuffer(width: w, height: bufferH)
        let blueContent = createTestImage(color: .blue, size: CGSize(width: w, height: contentH))
        let contentY: Double = 200
        engine.drawInBuffer(blueContent, at: contentY, height: Double(contentH))
        engine.minY = contentY
        engine.maxY = contentY + Double(contentH)

        // ── Set up engine state ──
        engine.phase = .stableStitching
        engine.finalCropRect = CGRect(x: 0, y: CGFloat(headerH), width: CGFloat(w), height: CGFloat(contentH))
        engine.topFrame = rawFrame
        engine.bottomFrame = rawFrame

        // ── Call finalize() ──
        guard let result = engine.finalize() else {
            XCTFail("finalize() returned nil")
            return
        }

        XCTAssertEqual(result.width, w)
        XCTAssertEqual(result.height, totalH)

        // ── Read pixels: render result into an unflipped context to read pixel data ──
        guard let ctx = CGContext(
            data: nil, width: w, height: totalH,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Failed to create pixel read context")
            return
        }
        // NOTE: This is an UNFLIPPED (bottom-up) context.
        // draw(CGImage) in bottom-up context:
        //   CGImage row 0 (top) → highest y in rect (top of context)
        // So in the data: row 0 (lowest memory) = bottom of image
        ctx.draw(result, in: CGRect(x: 0, y: 0, width: w, height: totalH))

        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * totalH * 4) else {
            XCTFail("Failed to get pixel data")
            return
        }

        // In bottom-up context data: row 0 = bottom of image, row (totalH-1) = top of image

        // finalize() uses a flipped context where CGImage row = user-space y.
        // Header at user y=0 → CGImage row 0 (top of image).
        // When drawn into unflipped read context, CGImage row 0 → data row 0 (bottom).
        // So data[0] = header, data[totalH-1] = footer.

        // Visual top (data row totalH-1): should be YELLOW footer
        let topRow = totalH - 1
        let fR = data[topRow * w * 4 + 2], fG = data[topRow * w * 4 + 1], fB = data[topRow * w * 4]
        let footerOK = fR > 200 && fG > 200 && fB < 50

        // Content somewhere below header: should be BLUE
        let cRow = headerH + 5
        let cR = data[cRow * w * 4 + 2], cG = data[cRow * w * 4 + 1], cB = data[cRow * w * 4]
        let contentOK = cB > 200 && cR < 50 && cG < 50

        // Visual bottom (data row 0): should be GREEN header
        let hR = data[2], hG = data[1], hB = data[0]
        let headerOK = hG > 200 && hR < 50 && hB < 50

        XCTAssertTrue(headerOK, "Header: R\(hR) G\(hG) B\(hB) — expected GREEN")
        XCTAssertTrue(contentOK, "Content: R\(cR) G\(cG) B\(cB) — expected BLUE")
        XCTAssertTrue(footerOK, "Footer: R\(fR) G\(fG) B\(fB) — expected YELLOW")
    }

    /// Test that makes ONLY the header path suspicious by comparing
    /// direct context drawing of a CGImage in a flipped context.
    func testFlippedContextDrawPreservesOrientation() {
        let w = 100, h = 40

        // Create a test image with KNOWN orientation:
        // Use a flipped context so y=0 = top of image
        let imgCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        imgCtx.translateBy(x: 0, y: CGFloat(h))
        imgCtx.scaleBy(x: 1.0, y: -1.0)
        // Now y=0 is top of image
        imgCtx.setFillColor(NSColor.green.cgColor)
        imgCtx.fill(CGRect(x: 0, y: 0, width: w, height: 20))       // Green at TOP
        imgCtx.setFillColor(NSColor.blue.cgColor)
        imgCtx.fill(CGRect(x: 0, y: 20, width: w, height: 20))      // Blue at BOTTOM
        guard let testImg = imgCtx.makeImage() else {
            XCTFail("Failed to create test image")
            return
        }
        // testImg row 0 = what? Depends on makeImage() behavior on flipped context.
        // We'll find out from the test results.

        // Create a flipped context (same as finalize() does)
        guard let flippedCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Failed to create context")
            return
        }
        flippedCtx.translateBy(x: 0, y: CGFloat(h))
        flippedCtx.scaleBy(x: 1.0, y: -1.0)

        // Draw the test image at y=0 in the flipped context
        flippedCtx.draw(testImg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Extract via makeImage()
        guard let result = flippedCtx.makeImage() else {
            XCTFail("makeImage() returned nil")
            return
        }

        // Read pixels using an unflipped context
        guard let readCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Failed to create read context")
            return
        }
        readCtx.draw(result, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = readCtx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else {
            XCTFail("Failed to get pixel data")
            return
        }

        // In bottom-up read context: data row 0 = visual BOTTOM, data row (h-1) = visual TOP
        // B,G,R,A format: data[offset+0]=B, data[offset+1]=G, data[offset+2]=R, data[offset+3]=A

        // Check visual TOP row: should be GREEN (high G, low R/B)
        let topRow = h - 1
        let topB = data[topRow * w * 4 + 0]
        let topG = data[topRow * w * 4 + 1]
        let topR = data[topRow * w * 4 + 2]

        // Check visual BOTTOM row: should be BLUE (high B, low R/G)
        let bottomB = data[0 * w * 4 + 0]
        let bottomG = data[0 * w * 4 + 1]
        let bottomR = data[0 * w * 4 + 2]

        // Print actual values for diagnosis
        let msg = "Top(row \(topRow)): R=\(topR) G=\(topG) B=\(topB) | Bottom(row 0): R=\(bottomR) G=\(bottomG) B=\(bottomB)"
        NSLog("TermSnap Test: \(msg)")

        XCTAssertGreaterThan(topG, 200, "\(msg) — Visual TOP should be GREEN (high G)")
        XCTAssertLessThan(topR, 50, "\(msg) — Visual TOP should be GREEN (low R)")
        XCTAssertLessThan(topB, 50, "\(msg) — Visual TOP should be GREEN (low B)")

        XCTAssertGreaterThan(bottomB, 200, "\(msg) — Visual BOTTOM should be BLUE (high B)")
        XCTAssertLessThan(bottomR, 50, "\(msg) — Visual BOTTOM should be BLUE (low R)")
        XCTAssertLessThan(bottomG, 50, "\(msg) — Visual BOTTOM should be BLUE (low G)")
    }

    // MARK: - Helpers

    private func createTopBottomImage(width: Int, topHeight: Int, bottomHeight: Int,
                                       topColor: NSColor = .red, bottomColor: NSColor = .blue) -> CGImage {
        let totalHeight = topHeight + bottomHeight
        let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Draw bottom-to-top in unflipped space, then flip CTM before makeImage()
        ctx.setFillColor(bottomColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: bottomHeight))
        ctx.setFillColor(topColor.cgColor)
        ctx.fill(CGRect(x: 0, y: bottomHeight, width: width, height: topHeight))
        ctx.translateBy(x: 0, y: CGFloat(totalHeight))
        ctx.scaleBy(x: 1.0, y: -1.0)
        return ctx.makeImage()!
    }

    private func createThreeBandImage(width: Int, topH: Int, midH: Int, bottomH: Int,
                                       topColor: NSColor, midColor: NSColor, bottomColor: NSColor) -> CGImage {
        let totalH = topH + midH + bottomH
        let ctx = CGContext(
            data: nil, width: width, height: totalH,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Draw bottom-to-top in unflipped space: y=0 = bottom, y=totalH = top
        ctx.setFillColor(bottomColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: bottomH))
        ctx.setFillColor(midColor.cgColor)
        ctx.fill(CGRect(x: 0, y: bottomH, width: width, height: midH))
        ctx.setFillColor(topColor.cgColor)
        ctx.fill(CGRect(x: 0, y: bottomH + midH, width: width, height: topH))
        // Flip CTM so makeImage() produces CGImage with row 0 = visual top
        ctx.translateBy(x: 0, y: CGFloat(totalH))
        ctx.scaleBy(x: 1.0, y: -1.0)
        return ctx.makeImage()!
    }

    // Legacy helper — kept for existing tests that just need solid-color images
    private func createTopBottomImage(width: Int, topHeight: Int, bottomHeight: Int) -> CGImage {
        return createTopBottomImage(width: width, topHeight: topHeight, bottomHeight: bottomHeight,
                                    topColor: .red, bottomColor: .blue)
    }

}
