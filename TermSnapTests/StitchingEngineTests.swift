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
        // Tiled buffer: setupBuffer(width:) sets frameWidth and clears tiles.
        engine.setupBuffer(width: 100)

        // Create a test image: red at top, blue at bottom (40px tall).
        let img = createTopBottomImage(width: 100, topHeight: 20, bottomHeight: 20)

        // Draw it at document y=200 (lands in tile yOffset=0, since tileHeight=4096).
        engine.drawInBuffer(img, at: 200, height: 40)

        // Read the tile back and verify the image was stored UPRIGHT: img row 0 (red, low B)
        // at doc y=200 -> tile-local row 200; img row 39 (blue, high B) at doc y=239.
        guard let tile = engine.tiles.first(where: { $0.yOffset == 0 }) else {
            XCTFail("no tile allocated for doc y=200")
            return
        }
        guard let tileImage = tile.context.makeImage() else {
            XCTFail("failed to make tile image")
            return
        }
        XCTAssertEqual(rawGray(tileImage, row: 200), 0, accuracy: 10,
                       "doc y=200 should be RED (img row 0, low B) - got B=\(rawGray(tileImage, row: 200))")
        XCTAssertEqual(rawGray(tileImage, row: 239), 255, accuracy: 10,
                       "doc y=239 should be BLUE (img row 39, high B) - got B=\(rawGray(tileImage, row: 239))")
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
        engine.setupBuffer(width: w)
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

        // finalize() composites header (top) -> content -> footer (bottom). Verify via raw
        // data-provider reads on the result CGImage (row 0 = top): green header at row 0,
        // blue content mid, yellow footer at the bottom row.
        let headerG = rawGray(result, row: 0, channel: 1)              // green -> G high
        let headerR = rawGray(result, row: 0, channel: 2)
        let headerOK = headerG > 200 && headerR < 50

        let contentB = rawGray(result, row: headerH + 5, channel: 0)   // blue -> B high
        let contentR = rawGray(result, row: headerH + 5, channel: 2)
        let contentOK = contentB > 200 && contentR < 50

        let footerR = rawGray(result, row: totalH - 1, channel: 2)    // yellow -> R high
        let footerB = rawGray(result, row: totalH - 1, channel: 0)
        let footerOK = footerR > 200 && footerB < 50

        XCTAssertTrue(headerOK, "Header (top row 0): G=\(headerG) R=\(headerR) - expected GREEN")
        XCTAssertTrue(contentOK, "Content (mid): B=\(contentB) R=\(contentR) - expected BLUE")
        XCTAssertTrue(footerOK, "Footer (bottom row \(totalH - 1)): R=\(footerR) B=\(footerB) - expected YELLOW")
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

    // MARK: - P5: Scroll sign-convention regression

    /// A known downward scroll must stitch content in correct top-to-bottom order.
    ///
    /// Frame A = the top of a synthetic document; Frame B = the same document scrolled
    /// DOWN by `scrollDy` rows (B shows content that was below A's view). After feeding
    /// A then B through `.stableStitching`, the stitched output MUST show document row 0
    /// at the top with later rows below — not reversed — and `topFrame` must stay the
    /// baseline (document top) while `bottomFrame` becomes B (document bottom).
    ///
    /// This pins down the displacement sign convention: downward scroll must INCREASE
    /// `currentOffset` (later frames drawn further down the buffer = further down the
    /// document). If Vision's `alignmentTransform.ty` (or the correlation fallback) has
    /// the opposite sign, this test fails and the raw displacement must be negated in
    /// `StitchingEngine`.
    func testDownwardScrollPreservesContentOrder() async {
        let w = 160
        let frameH = 100
        let scrollDy = 25
        let docH = frameH + scrollDy + 15            // 140; margin so B ends with unique rows

        let doc = makeSyntheticDocument(width: w, height: docH)
        let frameA = cropRows(doc, from: 0, length: frameH)!
        let frameB = cropRows(doc, from: scrollDy, length: frameH)!

        // Drive the engine into .stableStitching with A as baseline. Full-frame crop = no chrome.
        engine.reset()
        engine.setupBuffer(width: w)
        engine.frameWidth = w
        engine.frameHeight = frameH
        engine.finalCropRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(frameH))
        let initialOffset = engine.currentOffset      // == 0 (top of document) after reset
        engine.minY = initialOffset
        engine.maxY = initialOffset + Double(frameH)
        engine.topFrame = frameA
        engine.bottomFrame = frameA
        engine.baselineFrame = frameA
        engine.drawInBuffer(frameA, at: initialOffset, height: Double(frameH))
        engine.phase = .stableStitching
        engine.contentBandDetected = true   // test the pure stitch path with a pre-set crop
        engine.lastFrame = frameA

        // Feed B (scrolled down by scrollDy). Engine detects dy and draws B.
        _ = await engine.addFrame(frameB)

        // (1) Sign: downward scroll must push currentOffset DOWN the document (increase).
        XCTAssertGreaterThan(
            engine.currentOffset, initialOffset,
            "Downward scroll should INCREASE currentOffset (got \(engine.currentOffset), was \(initialOffset))"
        )

        // (2) Header/footer: topFrame = baseline (frameA = document top);
        //     bottomFrame = B (document bottom).
        XCTAssertTrue(imagesMatch(engine.topFrame!, frameA, tolerance: 12),
                      "topFrame should be frameA (document top)")
        XCTAssertTrue(imagesMatch(engine.bottomFrame!, frameB, tolerance: 12),
                      "bottomFrame should be frameB (document bottom)")

        // (3) Content order: stitched content must equal doc[0 ..< frameH+scrollDy]
        //     (top-to-bottom). Orientation-agnostic pixel compare - both images are
        //     rendered through the identical path, so a reversed stitch mismatches.
        guard let result = engine.finalize() else { XCTFail("finalize() returned nil"); return }
        XCTAssertEqual(result.width, w)
        XCTAssertEqual(result.height, frameH + scrollDy, "stitched height should be frameH + scrollDy")
        let expectedContent = cropRows(doc, from: 0, length: frameH + scrollDy)!
        let diff = firstDiff(result, expectedContent, tolerance: 14)
        XCTAssertNil(diff, "stitched content should match doc[0..<\(frameH + scrollDy)] in order — \(diff ?? "")")
    }

    // MARK: - P3: tiled buffer crosses a 4096px tile boundary

    /// The growable tiled buffer must correctly stitch content that spans more than one
    /// 4096px tile, including a frame whose draw range crosses the boundary (it must be
    /// split across two tiles) and `renderContentRange` must composite both tiles back into
    /// a continuous image. Verified with a tall gradient: row y -> gray = y*255/(h-1),
    /// checking rows around the 4096 seam for any discontinuity.
    func testTiledBufferCrossesTileBoundary() {
        let w = 100
        let segH = 1000
        let docH = 5000   // > tileHeight (4096), so the last segment crosses the boundary
        let doc = makeGradientDocument(width: w, height: docH)

        engine.reset()
        engine.setupBuffer(width: w)
        engine.frameWidth = w
        engine.frameHeight = segH
        engine.finalCropRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(segH))
        engine.phase = .stableStitching
        // Draw 5 segments end-to-end; segment 4 ([4000,5000)) straddles the 4096 boundary.
        for i in 0..<5 {
            let seg = cropRows(doc, from: i * segH, length: segH)!
            engine.drawInBuffer(seg, at: Double(i * segH), height: Double(segH))
        }
        engine.minY = 0
        engine.maxY = Double(docH)
        engine.topFrame = cropRows(doc, from: 0, length: segH)!
        engine.bottomFrame = cropRows(doc, from: docH - segH, length: segH)!

        // Two tiles should exist: yOffset 0 and yOffset 4096.
        XCTAssertEqual(engine.tiles.count, 2, "expected 2 tiles (0 and 4096), got \(engine.tiles.map { $0.yOffset })")

        guard let result = engine.renderContentRange(0, Double(docH)) else {
            XCTFail("renderContentRange returned nil"); return
        }
        XCTAssertEqual(result.width, w)
        XCTAssertEqual(result.height, docH)

        // Gradient must be intact across the whole range, especially around row 4096.
        for y in [0, 1000, 2000, 3000, 4095, 4096, 4500, docH - 1] {
            let got = rawGray(result, row: y)
            let expected = Int((CGFloat(y) * 255.0 / CGFloat(docH - 1)).rounded())
            XCTAssertEqual(got, expected, accuracy: 2,
                           "row \(y): got B=\(got), expected ~\(expected) (gradient broken at tile boundary?)")
        }
    }

    // MARK: - P1: overlap-band NCC displacement detection

    /// `detectOverlapDisplacement` must recover a known vertical displacement with high
    /// confidence and the correct sign, directly (without going through the engine).
    func testNCCDetectsKnownDisplacement() {
        let w = 160, frameH = 100, scrollDy = 25
        let doc = makeSyntheticDocument(width: w, height: frameH + scrollDy + 15)
        let frameA = cropRows(doc, from: 0, length: frameH)!
        let frameB = cropRows(doc, from: scrollDy, length: frameH)!   // scrolled DOWN 25

        guard let result = MotionDifferencingEngine.detectOverlapDisplacement(last: frameA, current: frameB, maxDy: 80) else {
            XCTFail("NCC returned nil for a known 25px downward scroll"); return
        }
        XCTAssertEqual(result.dy, Double(scrollDy), accuracy: 1.0,
                       "NCC dy should be ~+\(scrollDy) for downward scroll (got \(result.dy))")
        XCTAssertGreaterThan(result.confidence, 0.5,
                             "NCC confidence should be > 0.5 for a clear match (got \(result.confidence))")
    }

    /// NCC must recover the sign for an UPWARD scroll (dy < 0).
    func testNCCDetectsUpwardDisplacement() {
        let w = 160, frameH = 100, scrollDy = 25
        let doc = makeSyntheticDocument(width: w, height: frameH + scrollDy + 15)
        // frameB is ABOVE frameA in the document (scrolled UP by scrollDy).
        let frameA = cropRows(doc, from: scrollDy, length: frameH)!
        let frameB = cropRows(doc, from: 0, length: frameH)!

        guard let result = MotionDifferencingEngine.detectOverlapDisplacement(last: frameA, current: frameB, maxDy: 80) else {
            XCTFail("NCC returned nil for a known 25px upward scroll"); return
        }
        XCTAssertEqual(result.dy, Double(-scrollDy), accuracy: 1.0,
                       "NCC dy should be ~-\(scrollDy) for upward scroll (got \(result.dy))")
    }

    // MARK: - P8: content-band detection (chrome exclusion)

    /// `runDetection` (the off-main detection used by stableStitching) must find a known
    /// displacement when called directly, confirming the detection logic itself works
    /// independent of the `Task.detached` dispatch.
    func testRunDetectionFindsDisplacement() {
        let w = 160, frameH = 100, scrollDy = 25
        let doc = makeSyntheticDocument(width: w, height: frameH + scrollDy + 15)
        let frameA = cropRows(doc, from: 0, length: frameH)!
        let frameB = cropRows(doc, from: scrollDy, length: frameH)!
        guard let r = MotionDifferencingEngine.runDetection(contentLast: frameA, contentNew: frameB,
                                                   frameH: Double(frameH), scrollDelta: 0, accumulatedDyIn: 0) else {
            XCTFail("runDetection returned nil for a known 25px downward scroll"); return
        }
        XCTAssertEqual(r.dy, scrollDy, accuracy: 1, "runDetection dy should be ~25 (got \(r.dy))")
    }

    /// `detectContentBand` must find the moving content band and exclude static chrome
    /// (title bar / status bar) by comparing a baseline frame with a scrolled one.
    func testDetectContentBandExcludesStaticChrome() {
        let w = 100, h = 100
        let chromeTop = 15, chromeBottom = 85   // content occupies rows [15, 85)
        // Baseline: gray chrome top/bottom, gradient content in the middle (contentStart=0).
        let baseline = makeFramedGradient(width: w, height: h, chromeTop: chromeTop, chromeBottom: chromeBottom, contentStart: 0)
        // Current: content scrolled down 20 (contentStart=20); chrome unchanged.
        let current = makeFramedGradient(width: w, height: h, chromeTop: chromeTop, chromeBottom: chromeBottom, contentStart: 20)

        guard let band = MotionDifferencingEngine.detectContentBand(baseline: baseline, current: current) else {
            XCTFail("detectContentBand returned nil for a scrolled frame with static chrome"); return
        }
        // The detected content band should sit at/near the content region [chromeTop, chromeBottom),
        // NOT include the static chrome rows above/below it.
        XCTAssertGreaterThanOrEqual(band.topY, chromeTop - 2, "topY should be near content top (got \(band.topY))")
        XCTAssertLessThanOrEqual(band.topY, chromeTop + 2, "topY leaked into chrome (got \(band.topY))")
        XCTAssertGreaterThanOrEqual(band.bottomY, chromeBottom - 3, "bottomY leaked into chrome (got \(band.bottomY))")
        XCTAssertLessThanOrEqual(band.bottomY, chromeBottom, "bottomY should be near content bottom (got \(band.bottomY))")
    }

    // MARK: - Helpers

    /// Synthetic document: vertical brightness gradient (row 0 dark -> bottom bright)
    /// overlaid with a sparse grid of black dots, so Vision has strong 2D features to
    /// register while row-average gray stays monotonic for order verification.
    /// CGImage row 0 = visual top = document row 0.
    private func makeSyntheticDocument(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Flip so y=0 is the top of the image (CGImage row 0 = visual top).
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Gradient: row y -> gray = min(255, y*2)
        for y in 0..<height {
            let v = CGFloat(min(255, y * 2)) / 255.0
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1))
        }
        // 2D features: grid of 2x2 black dots.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for y in stride(from: 5, to: height, by: 7) {
            for x in stride(from: 3, to: width, by: 11) {
                ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 2, height: 2))
            }
        }
        return ctx.makeImage()!
    }

    /// Pure vertical gradient: row y -> gray = y*255/(height-1) (0 at top, 255 at bottom),
    /// monotonic across the full height so a corrupted stitch (e.g. at a tile boundary)
    /// shows up as a discontinuity. CGImage row 0 = visual top.
    private func makeGradientDocument(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)
        let denom = CGFloat(max(1, height - 1))
        for y in 0..<height {
            let v = CGFloat(y) / denom
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1))
        }
        return ctx.makeImage()!
    }

    /// A full frame with static gray chrome at top/bottom and a per-row gradient content band
    /// in the middle. `contentStart` shifts the gradient so two calls with different values
    /// simulate a scroll (content moves, chrome stays). CGImage row 0 = visual top.
    private func makeFramedGradient(width: Int, height: Int, chromeTop: Int, chromeBottom: Int, contentStart: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)   // y=0 = top
        // Static chrome (gray) fills the whole frame; content band overwrites the middle.
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let contentH = chromeBottom - chromeTop
        for y in 0..<contentH {
            let v = CGFloat((contentStart + y) % 256) / 255.0
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: 0, y: CGFloat(chromeTop + y), width: CGFloat(width), height: 1))
        }
        return ctx.makeImage()!
    }

    /// Crops rows [from, from+length) of `image` (CGImage top-left origin: row 0 = top).
    private func cropRows(_ image: CGImage, from: Int, length: Int) -> CGImage? {
        image.cropping(to: CGRect(x: 0, y: CGFloat(from), width: CGFloat(image.width), height: CGFloat(length)))
    }

    /// Ground-truth pixel read: returns the given channel value at CGImage row `r`, x `x`
    /// (BGRA layout: channel 0=B, 1=G, 2=R, 3=A). Reads the data provider directly, so it
    /// is unaffected by the row-flip ambiguity of drawing into a read context.
    private func rawGray(_ image: CGImage, row r: Int, x: Int = 0, channel: Int = 0) -> Int {
        guard let provider = image.dataProvider?.data else { return -1 }
        let ptr = CFDataGetBytePtr(provider)!
        return Int(ptr[r * image.bytesPerRow + x * 4 + channel])
    }

    /// Orientation-agnostic pixel comparison: renders both images into identical unflipped
    /// contexts and compares every byte. Both go through the same render path, so the
    /// row-0 convention cancels out - a mismatch means genuinely different content
    /// (e.g. a reversed stitch), not a coordinate-flip artifact. Returns nil on match,
    /// else a description of the first differing pixel.
    private func firstDiff(_ a: CGImage, _ b: CGImage, tolerance: Int) -> String? {
        guard a.width == b.width, a.height == b.height else {
            return "size mismatch a=\(a.width)x\(a.height) b=\(b.width)x\(b.height)"
        }
        let w = a.width, h = a.height
        let bytes = w * h * 4
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctxA = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        let ctxB = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let da = ctxA.data?.bindMemory(to: UInt8.self, capacity: bytes),
              let db = ctxB.data?.bindMemory(to: UInt8.self, capacity: bytes) else { return "no data" }
        for i in 0..<bytes {
            if abs(Int(da[i]) - Int(db[i])) > tolerance {
                let pixel = i / 4, channel = i % 4
                let y = pixel / w, x = pixel % w
                return "first diff at (x=\(x), y=\(y), ch=\(channel)): a=\(da[i]) b=\(db[i])"
            }
        }
        return nil
    }

    /// Orientation-agnostic pixel comparison: renders both images into identical unflipped
    /// contexts and compares every byte. Both go through the same render path, so the
    /// row-0 convention cancels out - a mismatch means genuinely different content
    /// (e.g. a reversed stitch), not a coordinate-flip artifact.
    private func imagesMatch(_ a: CGImage, _ b: CGImage, tolerance: Int) -> Bool {
        return firstDiff(a, b, tolerance: tolerance) == nil
    }

    private func createTopBottomImage(width: Int, topHeight: Int, bottomHeight: Int,
                                       topColor: NSColor = .red, bottomColor: NSColor = .blue) -> CGImage {
        let totalHeight = topHeight + bottomHeight
        let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Flip FIRST so y=0 = visual top; CGImage row 0 = topColor (upright).
        ctx.translateBy(x: 0, y: CGFloat(totalHeight))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.setFillColor(topColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(topHeight)))
        ctx.setFillColor(bottomColor.cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(topHeight), width: CGFloat(width), height: CGFloat(bottomHeight)))
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
        // Flip FIRST so y=0 = visual top; CGImage row 0 = topColor (upright).
        ctx.translateBy(x: 0, y: CGFloat(totalH))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.setFillColor(topColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(topH)))
        ctx.setFillColor(midColor.cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(topH), width: CGFloat(width), height: CGFloat(midH)))
        ctx.setFillColor(bottomColor.cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(topH + midH), width: CGFloat(width), height: CGFloat(bottomH)))
        return ctx.makeImage()!
    }

    // Legacy helper — kept for existing tests that just need solid-color images
    private func createTopBottomImage(width: Int, topHeight: Int, bottomHeight: Int) -> CGImage {
        return createTopBottomImage(width: width, topHeight: topHeight, bottomHeight: bottomHeight,
                                    topColor: .red, bottomColor: .blue)
    }

}
