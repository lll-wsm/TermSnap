import Vision
import CoreGraphics
import AppKit

enum StitchingPhase {
    case baseline
    case motionDetection
    case stableStitching
}

@MainActor
class StitchingEngine {
    internal var baselineFrame: CGImage?
    internal var lastFrame: CGImage?
    internal var phase: StitchingPhase = .baseline

    // Dynamic chrome sourcing: Track which frames are physically at the document top/bottom
    internal var topFrame: CGImage?
    internal var bottomFrame: CGImage?

    // Original frame dimensions
    internal var frameWidth: Int = 0
    internal var frameHeight: Int = 0

    // The exact verified scrolling area bounds (relative to the frame, top-down)
    internal var finalCropRect: CGRect?

    // Persistent buffer context (FLIPPED: top-left origin matching CGImage convention)
    internal var bufferContext: CGContext?
    private let bufferMaxHeight: Int = 20000

    // Document space uses CGImage-native top-down coordinates: 0 = top of document
    private let initialY: Double = 10000
    internal var minY: Double = 10000
    internal var maxY: Double = 10000
    private var currentOffset: Double = 10000

    // Independent header/footer frame tracking (decoupled from buffer positioning).
    // With current dy convention, downward scroll → currentOffset DECREASES,
    // so HIGHER currentOffset = closer to document TOP.
    private var headerBoundary: Double = 10000   // highest currentOffset seen → document top
    private var footerBoundary: Double = 10000   // lowest currentOffset seen → document bottom

    var lastDy: Double = 0
    private var accumulatedDy: Double = 0
    private var frameCount = 0

    func reset() {
        bufferContext = nil
        baselineFrame = nil
        lastFrame = nil
        topFrame = nil
        bottomFrame = nil
        phase = .baseline
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
    }

    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        let frameH = Double(newFrame.height)
        let frameW = Double(newFrame.width)

        switch phase {
        case .baseline:
            self.frameWidth = newFrame.width
            self.frameHeight = newFrame.height
            setupBuffer(width: newFrame.width, height: bufferMaxHeight)
            baselineFrame = newFrame
            lastFrame = newFrame
            phase = .motionDetection
            frameCount = 1
            return finalize()

        case .motionDetection:
            guard let last = lastFrame, let baseline = baselineFrame else { return finalize() }

            let handler = VNImageRequestHandler(cgImage: last, options: [:])
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)

            do {
                try handler.perform([registrationRequest])
                guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                    self.lastFrame = newFrame
                    return finalize()
                }

                let transform = observation.alignmentTransform
                // ty > 0 means content shifted UP relative to last in Vision (Y-up)
                // In Top-Down (Y-down), this means document content is moving UP
                // which is Scrolling DOWN. So rawDy > 0 = Scrolling DOWN.
                let rawDy = Double(transform.ty)
                self.accumulatedDy += rawDy
                let totalDy = Int(round(self.accumulatedDy))

                if abs(totalDy) >= 5 {
                    if let bounds = MotionDifferencingEngine.detectContentRect(baseline: baseline, current: newFrame, dy: totalDy) {
                        let topY = max(0, bounds.topY - 10)
                        let bottomY = min(Int(frameH) - 1, bounds.bottomY + 10)
                        let cropH = bottomY - topY + 1

                        self.finalCropRect = CGRect(x: 0, y: CGFloat(topY), width: CGFloat(frameW), height: CGFloat(cropH))

                        if let crop = self.finalCropRect,
                           let croppedBaseline = baseline.cropping(to: crop) {

                            self.minY = initialY
                            self.currentOffset = initialY
                            self.maxY = initialY + Double(cropH)

                            // Initialize chrome frame tracking
                            self.topFrame = baseline
                            self.bottomFrame = baseline
                            self.headerBoundary = initialY
                            self.footerBoundary = initialY

                            drawInBuffer(croppedBaseline, at: currentOffset, height: Double(cropH))
                        }

                        self.phase = .stableStitching
                        self.lastFrame = baseline
                        self.accumulatedDy = 0
                        return await addFrame(newFrame)
                    }
                }
            } catch { }

            lastFrame = newFrame
            return finalize()

        case .stableStitching:
            guard let last = lastFrame, let cropRect = finalCropRect else { return finalize() }
            if newFrame.width != last.width { return finalize() }

            let handler = VNImageRequestHandler(cgImage: last, options: [:])
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)

            do {
                try handler.perform([registrationRequest])
                guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                    return finalize()
                }

                let transform = observation.alignmentTransform
                let rawDy = Double(transform.ty)
                self.lastDy = rawDy
                self.accumulatedDy += rawDy
                frameCount += 1

                let dy = Int(round(accumulatedDy))
                if abs(dy) == 0 { return finalize() }

                if abs(dy) > Int(frameH / 2) {
                    lastFrame = newFrame
                    accumulatedDy = 0
                    return finalize()
                }

                accumulatedDy -= Double(dy)
                currentOffset += Double(dy)

                if let croppedNewFrame = newFrame.cropping(to: cropRect) {
                    drawInBuffer(croppedNewFrame, at: currentOffset, height: Double(cropRect.height))

                    // ── Buffer crop range tracking ──
                    if currentOffset < minY {
                        minY = currentOffset
                    }
                    let frameBottom = currentOffset + Double(cropRect.height)
                    if frameBottom > maxY {
                        maxY = frameBottom
                    }

                    // ── Header/footer frame tracking (independent from buffer positioning) ──
                    // currentOffset DECREASES on downward scroll, so HIGHER currentOffset
                    // means closer to document TOP → header source.
                    if currentOffset > headerBoundary {
                        headerBoundary = currentOffset
                        topFrame = newFrame
                    }
                    // LOWER currentOffset means closer to document BOTTOM → footer source.
                    if currentOffset < footerBoundary {
                        footerBoundary = currentOffset
                        bottomFrame = newFrame
                    }
                }

                lastFrame = newFrame
                return finalize()
            } catch { }
            return finalize()
        }
    }

    // MARK: - Buffer (flipped: top-left origin, matching CGImage convention)

    internal func setupBuffer(width: Int, height: Int) {
        bufferContext = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        // Flip to top-left origin so y=0 is top, y increases downward (matches CGImage convention)
        bufferContext?.translateBy(x: 0, y: CGFloat(height))
        bufferContext?.scaleBy(x: 1.0, y: -1.0)
        bufferContext?.setFillColor(NSColor.white.cgColor)
        bufferContext?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    internal func drawInBuffer(_ image: CGImage, at topDownY: Double, height: Double) {
        guard let ctx = bufferContext else { return }
        // Buffer is flipped (top-left origin). draw(CGImage, in:) always orients
        // the CGImage correctly, so the image is drawn upright with its top at topDownY.
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(topDownY), width: CGFloat(image.width), height: CGFloat(height)))
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
        guard let fullBuffer = bufferContext?.makeImage(),
              let cropRect = finalCropRect,
              let tFrame = topFrame,
              let bFrame = bottomFrame else {
            return lastFrame ?? baselineFrame
        }

        // Before stableStitching begins (baseline or motionDetection phase),
        // there's nothing to composite — return the raw frame as-is.
        if phase != .stableStitching { return lastFrame ?? baselineFrame }

        // ── Step 1: Extract the stitched scrolling content from the buffer ──
        //
        // The buffer context was flipped at setup time to top-left origin.
        // `makeImage()` on a flipped context produces a CGImage where:
        //   CGImage row 0  =  buffer y = 0  =  top of buffer
        //
        // Content frames were drawn at increasing `currentOffset` values as the
        // user scrolled down. `minY` tracks the smallest offset (earliest content,
        // closest to top of document) and `maxY` the largest (latest content,
        // furthest down).
        //
        // We crop from CGImage row `minY` to `maxY`, extracting exactly the
        // stitched content band, skipping the white padding above and below.
        let contentHeight = Int(ceil(maxY - minY))
        guard contentHeight > 0 else { return lastFrame ?? baselineFrame }

        let bufferCropRect = CGRect(
            x: 0,
            y: CGFloat(minY),
            width: CGFloat(fullBuffer.width),
            height: CGFloat(contentHeight)
        )
        guard let stitchedImage = fullBuffer.cropping(to: bufferCropRect) else {
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
                let flipped = flipImageVertically(img, height: headerHeight)
                let destRect = CGRect(
                    x: 0, y: 0,
                    width: CGFloat(width), height: CGFloat(headerHeight)
                )
                finalContext.draw(flipped, in: destRect)
            }
        }

        // Layer 2: Stitched scrolling content (middle)
        let stitchedRect = CGRect(
            x: 0, y: CGFloat(headerHeight),
            width: CGFloat(width), height: CGFloat(contentHeight)
        )
        finalContext.draw(stitchedImage, in: stitchedRect)

        // Layer 3: Footer chrome (at user y=headerH+contentH → CGImage row near totalH → bottom of output)
        if footerHeight > 0 {
            let sourceRect = CGRect(
                x: 0, y: CGFloat(footerSourceY),
                width: CGFloat(width), height: CGFloat(footerHeight)
            )
            if let img = bFrame.cropping(to: sourceRect) {
                let flipped = flipImageVertically(img, height: footerHeight)
                let destRect = CGRect(
                    x: 0, y: CGFloat(headerHeight + contentHeight),
                    width: CGFloat(width), height: CGFloat(footerHeight)
                )
                finalContext.draw(flipped, in: destRect)
            }
        }

        return finalContext.makeImage()
    }

    /// Flips an image vertically by drawing it in a temporary flipped context.
    private func flipImageVertically(_ image: CGImage, height: Int) -> CGImage {
        let w = image.width
        guard let ctx = CGContext(
            data: nil, width: w, height: height,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: height))
        return ctx.makeImage() ?? image
    }
}
