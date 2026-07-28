import CoreGraphics
import AppKit
import OSLog

fileprivate nonisolated let stitchingLog = Logger(subsystem: "com.lll.TermSnap", category: "Stitching")

enum StitchingPhase {
    case baseline
    case stableStitching
}

@MainActor
class StitchingEngine {
    internal var baselineFrame: CGImage?
    internal var lastFrame: CGImage?
    internal var phase: StitchingPhase = .baseline
    /// False until the first scrolled frame is seen; then the moving content band is
    /// detected (excluding static chrome) and `finalCropRect` is set. Tests may set this
    /// true to bypass detection and stitch a pre-set crop directly.
    internal var contentBandDetected = false

    // Dynamic chrome sourcing: Track which frames are physically at the document top/bottom
    internal var topFrame: CGImage?
    internal var bottomFrame: CGImage?

    // Original frame dimensions
    internal var frameWidth: Int = 0
    internal var frameHeight: Int = 0

    // The exact verified scrolling area bounds (relative to the frame, top-down)
    internal var finalCropRect: CGRect?

    // Persistent buffer: growable tiles (FLIPPED: top-left origin matching CGImage
    // convention). A single fixed-height buffer would truncate long pages or waste memory
    // on wide/retina captures, so content is stored in `tileHeight`-tall tiles allocated
    // on demand as the document grows in either direction.
    internal private(set) var tiles: [Tile] = []
    internal let tileHeight: Int = 4096

    // Document space uses CGImage-native top-down coordinates: 0 = top of document.
    // currentOffset starts at 0 (top) and grows downward as the user scrolls down;
    // scrolling up grows it negative. Tiles allocate for whatever range is touched.
    private let initialY: Double = 0
    internal var minY: Double = 0
    internal var maxY: Double = 0
    internal var currentOffset: Double = 0

    // Independent header/footer frame tracking (decoupled from buffer positioning).
    // Convention: downward scroll → currentOffset INCREASES (later frames are drawn
    // further down the buffer = further down the document). So the SMALLEST currentOffset
    // is the document TOP (first frame) and the LARGEST is the BOTTOM.
    // headerBoundary tracks the min (→ topFrame), footerBoundary tracks the max (→ bottomFrame).
    private var headerBoundary: Double = 10000   // smallest currentOffset seen → document top
    private var footerBoundary: Double = 10000   // largest currentOffset seen → document bottom

    var lastDy: Double = 0
    private var accumulatedDy: Double = 0
    private var frameCount = 0
    /// Advances every addFrame; the live preview is generated only every Nth frame to
    /// avoid running the expensive full-buffer `makeImage()` on each captured frame.
    private var previewThrottleCounter = 0

    /// External scroll hint from CGEvent monitoring — cumulative scrollingDeltaY since capture start.
    /// Set by OverlayView to provide ground-truth scroll displacement
    /// when image-based methods (Vision, correlation) fail on uniform content.
    var hintedDy: Double = 0
    private var lastHintedDy: Double = 0

    /// Number of consecutive frames with no detectable displacement.
    /// When this exceeds the threshold, scrolling has likely stopped.
    private(set) var idleFrameCount: Int = 0

    /// True when enough idle frames have passed to auto-finish the capture.
    var shouldAutoFinish: Bool { idleFrameCount >= 20 }

    func reset() {
        tiles = []
        baselineFrame = nil
        lastFrame = nil
        topFrame = nil
        bottomFrame = nil
        phase = .baseline
        contentBandDetected = false
        frameWidth = 0
        frameHeight = 0
        finalCropRect = nil

        minY = initialY
        maxY = initialY
        currentOffset = initialY
        headerBoundary = initialY
        footerBoundary = initialY
        lastDy = 0
        accumulatedDy = 0
        frameCount = 0
        hintedDy = 0
        lastHintedDy = 0
        idleFrameCount = 0
        previewThrottleCounter = 0
    }

    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        let frameH = Double(newFrame.height)
        let frameW = Double(newFrame.width)

        switch phase {
        case .baseline:
            stitchingLog.notice("BASELINE: capturing first frame (w=\(newFrame.width) h=\(newFrame.height))")
            self.frameWidth = newFrame.width
            self.frameHeight = newFrame.height
            setupBuffer(width: newFrame.width)
            baselineFrame = newFrame
            lastFrame = newFrame
            frameCount = 1
            self.accumulatedDy = 0
            // Don't draw yet - wait for the first scrolled frame so the moving content band
            // can be detected (excluding static chrome). finalCropRect is set in stableStitching
            // once motion is seen; until then previewImage falls back to the raw baseline.
            self.phase = .stableStitching
            return previewImage()

        case .stableStitching:
            guard let last = lastFrame, let baseline = baselineFrame else { return previewImage() }
            if newFrame.width != last.width { return previewImage() }

            // Before the content band is detected, operate on the full frame; after, use the
            // detected content crop (static chrome excluded) for both detection and drawing.
            let cropRect = finalCropRect ?? CGRect(x: 0, y: 0, width: CGFloat(frameW), height: CGFloat(frameH))
            let contentLast = last.cropping(to: cropRect) ?? last
            let contentNew = newFrame.cropping(to: cropRect) ?? newFrame

            let scrollDelta = self.hintedDy - self.lastHintedDy
            self.lastHintedDy = self.hintedDy

            // Heavy detection (NCC -> Vision -> correlation -> scrollEvent) off the main
            // thread. runDetection is a pure nonisolated static func on MotionDifferencingEngine
            // (no self access), so it runs on the detached task's background executor; engine
            // state is applied back on main when it returns.
            let accIn = self.accumulatedDy
            let detection = await Task.detached(priority: .userInitiated) {
                MotionDifferencingEngine.runDetection(contentLast: contentLast, contentNew: contentNew,
                                                     frameH: frameH, scrollDelta: scrollDelta,
                                                     accumulatedDyIn: accIn)
            }.value

            guard let (dy, dySource, newAccum, lastDyVal) = detection else {
                idleFrameCount += 1
                return throttledPreviewImage()
            }
            self.accumulatedDy = newAccum
            self.lastDy = lastDyVal

            // First detected motion: find the moving content band (exclude static chrome) and
            // initialize the buffer with the baseline's content band. Without this, the static
            // title bar / status bar would be stamped into the stitch at every frame offset.
            if !contentBandDetected {
                contentBandDetected = true
                let band = MotionDifferencingEngine.detectContentBand(baseline: baseline, current: newFrame)
                if let b = band {
                    let t = max(0, b.topY)
                    let bo = min(Int(frameH) - 1, b.bottomY)
                    self.finalCropRect = CGRect(x: 0, y: CGFloat(t), width: CGFloat(frameW), height: CGFloat(bo - t + 1))
                } else {
                    // No clear content band (whole frame moved uniformly) - stitch the full frame.
                    self.finalCropRect = cropRect
                }
                let cropH = Double(self.finalCropRect?.height ?? CGFloat(frameH))
                self.minY = initialY
                self.currentOffset = initialY
                self.maxY = initialY + cropH
                self.topFrame = baseline
                self.bottomFrame = baseline
                self.headerBoundary = initialY
                self.footerBoundary = initialY
                if let crop = self.finalCropRect,
                   let croppedBaseline = baseline.cropping(to: crop) {
                    drawInBuffer(croppedBaseline, at: currentOffset, height: cropH)
                }
            }

            idleFrameCount = 0
            frameCount += 1

            if abs(dy) > Int(Double(frameH) * 0.7) {
                stitchingLog.info("StableStitch: dy too large (\(dy)), resetting")
                lastFrame = newFrame
                accumulatedDy = 0
                return throttledPreviewImage()
            }

            accumulatedDy -= Double(dy)
            currentOffset += Double(dy)

            stitchingLog.debug("StableStitch #\(self.frameCount): dy=\(dy) source=\(dySource) offset=\(String(format: "%.0f", self.currentOffset)) band=\(self.finalCropRect?.height ?? 0)")

            // Draw the current frame's content band at the advanced offset.
            if let drawCrop = self.finalCropRect,
               let croppedNewFrame = newFrame.cropping(to: drawCrop) {
                let overlap = max(0, Int(drawCrop.height) - dy)
                let feather = min(8, overlap)
                drawInBuffer(croppedNewFrame, at: currentOffset, height: Double(drawCrop.height), featherTop: feather)

                if currentOffset < minY { minY = currentOffset }
                let frameBottom = currentOffset + Double(drawCrop.height)
                if frameBottom > maxY { maxY = frameBottom }
                if currentOffset < headerBoundary { headerBoundary = currentOffset; topFrame = newFrame }
                if currentOffset > footerBoundary { footerBoundary = currentOffset; bottomFrame = newFrame }
            }

            lastFrame = newFrame
            return throttledPreviewImage()
        }
    }

    // MARK: - Buffer (flipped: top-left origin, matching CGImage convention)

    /// A `tileHeight`-tall slice of the document buffer. Tiles are allocated on demand and
    /// cover document y `[yOffset, yOffset + tileHeight)`. Each tile's context is flipped
    /// (top-left origin) so its CGImage row 0 == document row `yOffset`.
    internal struct Tile {
        let yOffset: Int
        let context: CGContext
    }

    internal func setupBuffer(width: Int) {
        frameWidth = width
        tiles = []
    }

    /// Returns the tile containing document row `docY`, creating it (white-filled, flipped)
    /// if it doesn't exist.
    private func ensureTile(forDocY docY: Int) -> Tile {
        let yOffset = floorDiv(docY, tileHeight) * tileHeight
        if let existing = tiles.first(where: { $0.yOffset == yOffset }) { return existing }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: frameWidth, height: tileHeight,
            bitsPerComponent: 8, bytesPerRow: frameWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
        )!
        ctx.translateBy(x: 0, y: CGFloat(tileHeight))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(frameWidth), height: CGFloat(tileHeight)))
        let tile = Tile(yOffset: yOffset, context: ctx)
        tiles.append(tile)
        return tile
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int {
        (a >= 0) ? (a / b) : -(((-a) + b - 1) / b)
    }

    /// Draws `image` upright into the (tiled) buffer at document y `topDownY`. When
    /// `featherTop > 0`, the top `featherTop` rows are blended over existing content with a
    /// 0..1 alpha ramp (instead of hard-overwritten) to hide sub-pixel misregistration seams
    /// at the stitch boundary. `featherTop` must be <= the overlap with the previous frame.
    internal func drawInBuffer(_ image: CGImage, at topDownY: Double, height: Double, featherTop: Int = 0) {
        let imgW = CGFloat(image.width)
        let feather = max(0, min(featherTop, max(0, image.height - 1)))
        let docY = Int(topDownY)  // currentOffset is integer-valued (dy is Int)
        // Hard-draw the portion below the feather band, routing across tiles as needed.
        drawSegmentHard(image, docRangeStart: docY + feather, docRangeEnd: docY + image.height,
                        topDownY: docY, width: imgW)
        // Feather the top `feather` rows: each is 1px and lands in a single tile; draw with
        // a ramped alpha so it composites over the existing buffer content (seam -> full).
        for i in 0..<feather {
            let alpha = CGFloat(i + 1) / CGFloat(feather + 1)
            guard let row = image.cropping(to: CGRect(x: 0, y: CGFloat(i), width: imgW, height: 1)) else { continue }
            let rowDocY = docY + i
            let tile = ensureTile(forDocY: rowDocY)
            tile.context.saveGState()
            tile.context.setAlpha(alpha)
            drawUpright(in: tile.context, image: row, topY: CGFloat(rowDocY - tile.yOffset), height: 1, width: imgW)
            tile.context.restoreGState()
        }
    }

    /// Draws image rows for the document range [docRangeStart, docRangeEnd), splitting at
    /// tile boundaries. `topDownY` is the document y of image row 0.
    private func drawSegmentHard(_ image: CGImage, docRangeStart: Int, docRangeEnd: Int, topDownY: Int, width: CGFloat) {
        guard docRangeEnd > docRangeStart else { return }
        var tileY = floorDiv(docRangeStart, tileHeight) * tileHeight
        while tileY < docRangeEnd {
            let segTop = max(docRangeStart, tileY)
            let segBottom = min(docRangeEnd, tileY + tileHeight)
            if segBottom > segTop {
                let imgRow = segTop - topDownY            // image row at document segTop
                let segH = segBottom - segTop
                if let seg = image.cropping(to: CGRect(x: 0, y: CGFloat(imgRow), width: width, height: CGFloat(segH))) {
                    let tile = ensureTile(forDocY: tileY)
                    drawUpright(in: tile.context, image: seg, topY: CGFloat(segTop - tileY), height: CGFloat(segH), width: width)
                }
            }
            tileY += tileHeight
        }
    }

    /// Composites the tiles covering document y [topY, bottomY) into a single upright
    /// CGImage (row 0 = document top). Used by both `previewImage()` and `finalize()`.
    internal func renderContentRange(_ topY: Double, _ bottomY: Double) -> CGImage? {
        let top = Int(floor(topY))
        let bottom = Int(ceil(bottomY))
        let contentH = bottom - top
        guard contentH > 0, frameWidth > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: frameWidth, height: contentH,
            bitsPerComponent: 8, bytesPerRow: frameWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(contentH))
        ctx.scaleBy(x: 1.0, y: -1.0)   // flipped: row 0 = top
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(frameWidth), height: CGFloat(contentH)))
        for tile in tiles {
            let segTop = max(top, tile.yOffset)
            let segBottom = min(bottom, tile.yOffset + tileHeight)
            guard segBottom > segTop else { continue }
            guard let tileImage = tile.context.makeImage() else { continue }
            let localTop = segTop - tile.yOffset
            let segH = segBottom - segTop
            guard let seg = tileImage.cropping(to: CGRect(x: 0, y: CGFloat(localTop), width: CGFloat(frameWidth), height: CGFloat(segH))) else { continue }
            drawUpright(in: ctx, image: seg, topY: CGFloat(segTop - top), height: CGFloat(segH), width: CGFloat(frameWidth))
        }
        return ctx.makeImage()
    }

    /// Draws `image` upright into a flipped (top-left origin) context so that its row 0
    /// lands at user-space y `topY` (top of the band [topY, topY+height]).
    /// `CGContext.draw` in a flipped context renders images upside-down; this counter-flips.
    private func drawUpright(in ctx: CGContext, image: CGImage, topY: CGFloat, height: CGFloat, width: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: topY + height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    /// Cheap preview image for the live scrolling panel: just the stitched content band
    /// `[minY, maxY]` cropped from the buffer, WITHOUT the header/footer chrome composite
    /// that `finalize()` builds. Called every Nth frame (see `throttledPreviewImage()`) so
    /// the expensive full-buffer `makeImage()` doesn't run on every captured frame.
    func previewImage() -> CGImage? {
        guard phase == .stableStitching else { return lastFrame ?? baselineFrame }
        return renderContentRange(minY, maxY) ?? lastFrame ?? baselineFrame
    }

    /// Returns a preview image only every Nth frame (nil otherwise) so the live panel
    /// skips the buffer `makeImage()` cost on most frames. The stitch itself still updates
    /// every frame; only the preview rendering is throttled.
    private func throttledPreviewImage() -> CGImage? {
        previewThrottleCounter += 1
        if previewThrottleCounter % 3 != 1 { return nil }
        return previewImage()
    }

    /// Assembles the final stitched screenshot by compositing three layers:
    /// [Header chrome] → [Scrolling content] → [Footer chrome]
    ///
    /// The output CGImage is a single upright image suitable for display and export.
    ///
    /// ## Data sources
    /// - **fullBuffer**: CGImage from the buffer (flipped) context's `makeImage()`.
    /// - **topFrame**: the raw frame at the document's uppermost scroll position;
    ///   its top portion contains window title bar chrome.
    /// - **bottomFrame**: the raw frame at the document's lowermost scroll position;
    ///   its bottom portion contains window footer (rounded corners, borders).
    ///
    /// ## Layer breakdown
    ///
    /// ```
    /// ┌──────────────────────┐  y=0 (top of final image)
    /// │  Header (title bar)  │  cropped from topFrame[0 ..< headerHeight]
    /// ├──────────────────────┤  y=headerHeight
    /// │                      │
    /// │  Stitched content    │  cropped from fullBuffer[minY ..< maxY]
    /// │  (scrollable area)   │
    /// │                      │
    /// ├──────────────────────┤  y=headerHeight + contentHeight
    /// │  Footer (corners)    │  cropped from bottomFrame[footerSourceY ..< end]
    /// └──────────────────────┘  y=totalHeight
    /// ```
    ///
    /// ## Coordinate system
    /// The final composite context is flipped (`translateBy` + `scaleBy(x:1, y:-1)`).
    /// `CGContext.makeImage()` on a flipped context produces a CGImage where
    /// row index equals user-space y: CGImage row 0 = user y=0 (top of image),
    /// CGImage row totalH = user y=totalH (bottom of image).
    /// Layers are stacked top-to-bottom in user space (header→content→footer).
    /// Header/footer images are pre-flipped via `flipImageVertically` so their
    /// internal orientation survives the single inversion from `makeImage()`
    /// (content from the buffer already carries its own pre-inversion from
    /// the buffer's flipped `makeImage()`).
    func finalize() -> CGImage? {
        // ── Guards: all required state must be present ────────────────────
        // If any piece is missing we can't assemble a composite, so fall back
        // to returning the last raw frame or baseline frame directly.
        guard let cropRect = finalCropRect,
              let tFrame = topFrame,
              let bFrame = bottomFrame else {
            return lastFrame ?? baselineFrame
        }

        // If we're still in the baseline phase (first frame not yet captured), there's
        // nothing to composite - return the raw frame as-is.
        if phase != .stableStitching { return lastFrame ?? baselineFrame }

        // Step 1: extract the stitched scrolling content from the tiled buffer.
        // renderContentRange composites the tiles covering [minY, maxY] into one upright
        // CGImage (row 0 = document top), skipping the white padding above and below.
        let contentHeight = Int(ceil(maxY - minY))
        guard contentHeight > 0 else { return lastFrame ?? baselineFrame }
        guard let stitchedImage = renderContentRange(minY, maxY) else {
            return lastFrame ?? baselineFrame
        }
        // stitchedImage is now an upright CGImage containing only the scrollable
        // content, in correct top-to-bottom order, with no chrome.

        // ── Step 2: Calculate the dimensions of each layer ──────────────────
        //
        // cropRect = finalCropRect, the detected content-area bounds within a
        // raw frame (in frame-local pixel coordinates, top-down).
        //
        //   cropRect.minY = top edge of content (below title bar)
        //   cropRect.maxY = bottom edge of content (above footer/rounded corners)
        //
        // Header height = cropRect.minY
        //   Everything above the content area in the frame is chrome (title bar,
        //   toolbar, window border). We take this from `topFrame` so the header
        //   reflects the window's appearance at the top of the document.
        //
        // Footer height = frame.height - cropRect.maxY
        //   Everything below the content area (rounded corners, bottom border).
        //   We take this from `bottomFrame` so the footer reflects the window's
        //   appearance at the bottom of the document.
        let headerHeight = Int(cropRect.minY)
        let footerSourceY = Int(cropRect.maxY)
        let footerHeight = Int(bFrame.height) - footerSourceY
        let totalHeight = headerHeight + contentHeight + max(0, footerHeight)
        let width = Int(cropRect.width)

        // ── Step 3: Create the final composite context ─────────────────────
        guard let finalContext = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return stitchedImage }

        // Flip context: (x, y) → (x, totalHeight - y)
        // User y=0 → top of device, user y=totalHeight → bottom of device.
        // makeImage() on a flipped context respects the CTM: CGImage row = user-space y.
        // So CGImage row 0 = user y=0 (top of image), row totalH = user y=totalH (bottom).
        finalContext.translateBy(x: 0, y: CGFloat(totalHeight))
        finalContext.scaleBy(x: 1.0, y: -1.0)

        // Fill with white background.
        finalContext.setFillColor(NSColor.white.cgColor)
        finalContext.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))

        // ── Step 4: Stack layers top-to-bottom in user space ──
        //   user y = 0                    → header  (→ CGImage row 0 = top of output)
        //   user y = headerHeight          → content (→ CGImage middle rows)
        //   user y = headerHeight+contentH → footer  (→ CGImage rows near totalHeight = bottom)

        // Layer 1: Header chrome (at user y=0 → CGImage row 0 → top of output)
        if headerHeight > 0 {
            let headerCropRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(headerHeight))
            if let img = tFrame.cropping(to: headerCropRect) {
                drawUpright(in: finalContext, image: img, topY: 0, height: CGFloat(headerHeight), width: CGFloat(width))
            }
        }

        // Layer 2: Stitched scrolling content (middle).
        drawUpright(in: finalContext, image: stitchedImage, topY: CGFloat(headerHeight), height: CGFloat(contentHeight), width: CGFloat(width))

        // Layer 3: Footer chrome (at user y=headerH+contentH → CGImage row near totalH → bottom of output)
        if footerHeight > 0 {
            let sourceRect = CGRect(
                x: 0, y: CGFloat(footerSourceY),
                width: CGFloat(width), height: CGFloat(footerHeight)
            )
            if let img = bFrame.cropping(to: sourceRect) {
                drawUpright(in: finalContext, image: img, topY: CGFloat(headerHeight + contentHeight), height: CGFloat(footerHeight), width: CGFloat(width))
            }
        }

        return finalContext.makeImage()
    }
}
