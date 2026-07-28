import Accelerate
import CoreGraphics
import Foundation
import OSLog
import Vision

private nonisolated let logger = Logger(subsystem: "com.lll.TermSnap", category: "MotionDifferencing")

nonisolated struct MotionDifferencingEngine {
    
    /// Detects the dynamic content boundary by comparing a baseline frame with a new frame that has moved by `dy`.
    /// - Parameters:
    ///   - baseline: The initial frame.
    ///   - current: The current frame after scrolling.
    ///   - dy: The vertical displacement (Top-Down: > 0 means scrolled DOWN).
    ///   - hintRect: Optional hint for localizing search.
    static func detectContentRect(baseline: CGImage, current: CGImage, dy: Int, hintRect: CGRect? = nil) -> (topY: Int, bottomY: Int)? {
        let width = baseline.width
        let height = baseline.height
        guard width == current.width, height == current.height else { return nil }

        // ── Path 1: motion-based detection (only when dy is meaningful) ──
        if dy != 0,
           let baseBuffer = vImageBuffer(cgImage: baseline),
           let currBuffer = vImageBuffer(cgImage: current) {

            defer {
                free(baseBuffer.data)
                free(currBuffer.data)
            }

            let count = width * 4
            var bufferA = [Float](repeating: 0, count: count)
            var bufferB = [Float](repeating: 0, count: count)
            var bufferC = [Float](repeating: 0, count: count)

            var isContent = [Bool](repeating: false, count: height)
            let tolerance: Float = 0.05

            for y in 0..<height {
                let shiftedY = y - dy

                let staticError = computeMSE(buffer1: currBuffer, row1: y, buffer2: baseBuffer, row2: y, width: width, temp1: &bufferA, temp2: &bufferB, temp3: &bufferC)
                let isStatic = staticError < tolerance

                if shiftedY >= 0 && shiftedY < height {
                    let movingError = computeMSE(buffer1: currBuffer, row1: y, buffer2: baseBuffer, row2: shiftedY, width: width, temp1: &bufferA, temp2: &bufferB, temp3: &bufferC)
                    let isMoving = movingError < tolerance

                    if isMoving && !isStatic {
                        isContent[y] = true
                    }
                } else {
                    if !isStatic {
                        isContent[y] = true
                    }
                }
            }

            var firstMotionRow: Int?
            var lastMotionRow: Int?
            var totalMotionRows = 0

            for y in 0..<height {
                if isContent[y] {
                    if firstMotionRow == nil { firstMotionRow = y }
                    lastMotionRow = y
                    totalMotionRows += 1
                }
            }

            logger.debug("Motion detection: dy=\(dy) totalMotionRows=\(totalMotionRows) firstRow=\(firstMotionRow ?? -1) lastRow=\(lastMotionRow ?? -1) frameH=\(height)")

            if let start = firstMotionRow, let end = lastMotionRow,
               totalMotionRows > 30,
               totalMotionRows > height / 5 {
                logger.info("Motion detection SUCCESS: topY=\(start) bottomY=\(end)")
                return (topY: start, bottomY: end)
            }
            logger.debug("Motion detection insufficient, falling back to brightness")
        } else if dy == 0 {
            logger.debug("dy=0, skipping motion detection, going directly to brightness")
        } else {
            logger.warning("vImageBuffer conversion failed for baseline or current")
        }

        // ── Path 2: brightness-based detection ──
        return detectByBrightness(current: current)
    }

    /// Detects the content area by finding brightness transitions (edges)
    /// between dark chrome and bright content. Uses the derivative of the
    /// smoothed row-brightness curve to find dark→bright (top) and
    /// bright→dark (bottom) transitions.
    private static func detectByBrightness(current: CGImage) -> (topY: Int, bottomY: Int)? {
        let width = current.width
        let height = current.height

        guard let buf = vImageBuffer(cgImage: current) else {
            logger.warning("detectByBrightness: vImageBuffer conversion failed")
            return nil
        }
        defer { free(buf.data) }

        let rowBytes = buf.rowBytes
        let data = buf.data.assumingMemoryBound(to: UInt8.self)

        // Compute per-row average brightness (Rec.709 luma)
        var rowBrightness = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let row = data.advanced(by: y * rowBytes)
            var sum: Float = 0
            for x in 0..<width {
                let offset = x * 4
                let r = Float(row[offset + 2])
                let g = Float(row[offset + 1])
                let b = Float(row[offset])
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            rowBrightness[y] = sum / Float(width)
        }

        let globalMin = rowBrightness.min() ?? 0
        let globalMax = rowBrightness.max() ?? 255
        logger.debug("Brightness range: min=\(String(format: "%.0f", globalMin)) max=\(String(format: "%.0f", globalMax))")

        // Smooth with running average to suppress pixel noise
        let smoothRadius = max(3, height / 120) // ~3 rows for typical 1200px frame
        var smoothed = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let start = max(0, y - smoothRadius)
            let end = min(height - 1, y + smoothRadius)
            var sum: Float = 0
            for i in start...end { sum += rowBrightness[i] }
            smoothed[y] = sum / Float(end - start + 1)
        }

        // Derivative: brightness change between consecutive smoothed rows
        var derivative = [Float](repeating: 0, count: height - 1)
        for y in 0..<(height - 1) {
            derivative[y] = smoothed[y + 1] - smoothed[y]
        }

        // Find the FIRST significant dark→bright transition scanning from top.
        // Skip the first few rows (window shadow/border artifacts).
        let skipTop = max(3, height / 150)
        var topBoundary: Int?
        for y in skipTop..<min(height * 2 / 5, height - 1) {
            if derivative[y] > 6 {
                topBoundary = y + 1
                break
            }
        }

        // Find the FIRST significant bright→dark transition scanning from bottom.
        var bottomBoundary: Int?
        for y in stride(from: height - 3, through: height * 3 / 5, by: -1) {
            if derivative[y] < -6 {
                bottomBoundary = y
                break
            }
        }

        logger.debug("Transitions: top=\(topBoundary ?? -1) (deriv=\(topBoundary != nil ? String(format: "%.1f", derivative[topBoundary! - 1]) : "n/a")) bottom=\(bottomBoundary ?? -1) (deriv=\(bottomBoundary != nil ? String(format: "%.1f", derivative[bottomBoundary!]) : "n/a"))")

        guard let top = topBoundary, let bottom = bottomBoundary, top < bottom else {
            logger.warning("Transition FAIL: could not find both transitions, top=\(topBoundary ?? -1) bottom=\(bottomBoundary ?? -1)")
            return nil
        }

        let contentHeight = bottom - top
        guard contentHeight > 30 else {
            logger.warning("Transition FAIL: content too thin (\(contentHeight)px)")
            return nil
        }

        // Verify the transition makes sense: content should be brighter than chrome
        let chromeTopBrightness = smoothed[max(0, top - 5)..<top].reduce(0, +) / Float(min(5, top))
        let contentMidBrightness = smoothed[top..<bottom].reduce(0, +) / Float(contentHeight)
        guard contentMidBrightness > chromeTopBrightness + 15 else {
            logger.warning("Transition FAIL: content not significantly brighter than chrome (chrome=\(String(format: "%.0f", chromeTopBrightness)) content=\(String(format: "%.0f", contentMidBrightness)))")
            return nil
        }

        logger.info("Transition SUCCESS: topY=\(top) bottomY=\(bottom) chromeBright=\(String(format: "%.0f", chromeTopBrightness)) contentBright=\(String(format: "%.0f", contentMidBrightness))")
        return (topY: top, bottomY: bottom)
    }
    
    // MARK: - Displacement detection (Vision fallback)

    /// Detects vertical displacement between two frames by correlating
    /// per-row brightness signatures. Does not require feature points,
    /// so it works on uniform content (e.g. white webpage) where Vision fails.
    /// - Returns: dy in pixels (positive = content scrolled DOWN / moved UP in image).
    static func detectDisplacement(baseline: CGImage, current: CGImage, maxDisplacement: Int = 80) -> Int? {
        let width = baseline.width
        let height = baseline.height
        guard width == current.width, height == current.height, height > 10 else { return nil }

        guard let bufA = vImageBuffer(cgImage: baseline),
              let bufB = vImageBuffer(cgImage: current) else {
            logger.warning("detectDisplacement: vImageBuffer conversion failed")
            return nil
        }
        defer { free(bufA.data); free(bufB.data) }

        let dataA = bufA.data.assumingMemoryBound(to: UInt8.self)
        let dataB = bufB.data.assumingMemoryBound(to: UInt8.self)
        let rowBytesA = bufA.rowBytes
        let rowBytesB = bufB.rowBytes

        // Compute per-row brightness signatures (Rec.709 luma sum per row, normalized by width)
        var sigA = [Float](repeating: 0, count: height)
        var sigB = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let rowA = dataA.advanced(by: y * rowBytesA)
            let rowB = dataB.advanced(by: y * rowBytesB)
            var sumA: Float = 0
            var sumB: Float = 0
            for x in 0..<width {
                let off = x * 4
                // BGRA: offset+0=B, +1=G, +2=R
                sumA += 0.2126 * Float(rowA[off + 2]) + 0.7152 * Float(rowA[off + 1]) + 0.0722 * Float(rowA[off])
                sumB += 0.2126 * Float(rowB[off + 2]) + 0.7152 * Float(rowB[off + 1]) + 0.0722 * Float(rowB[off])
            }
            sigA[y] = sumA / Float(width)
            sigB[y] = sumB / Float(width)
        }

        // Search for the offset that minimizes MSE over overlapping rows
        let searchRange = min(maxDisplacement, height / 2)
        var bestOffset = 0
        var bestError = Float.infinity

        for offset in -searchRange...searchRange {
            let overlapStart = max(0, offset)
            let overlapEnd = min(height, height + offset)
            let overlapCount = overlapEnd - overlapStart
            guard overlapCount > height / 4 else { continue }

            var error: Float = 0
            for y in overlapStart..<overlapEnd {
                let diff = sigB[y] - sigA[y - offset]
                error += diff * diff
            }
            error /= Float(overlapCount)

            if error < bestError {
                bestError = error
                bestOffset = offset
            }
        }

        // Require a meaningful improvement over the zero-offset error
        // (compute zero-offset error for reference)
        var zeroError: Float = 0
        for y in 0..<height {
            let diff = sigB[y] - sigA[y]
            zeroError += diff * diff
        }
        zeroError /= Float(height)

        let improvement = zeroError > 0 ? (zeroError - bestError) / zeroError : 0

        logger.debug("RowCorrelation: bestOffset=\(bestOffset) bestError=\(String(format: "%.4f", bestError)) zeroError=\(String(format: "%.4f", zeroError)) improvement=\(String(format: "%.1f", improvement * 100))%")

        // Require at least 20% improvement over zero to trust the result
        guard improvement > 0.2, abs(bestOffset) > 0 else {
            logger.debug("RowCorrelation: no clear displacement found")
            return nil
        }

        return bestOffset
    }

    // MARK: - Overlap-band NCC displacement detection (primary, sub-pixel)

    /// Detects vertical displacement by 2D normalized cross-correlation of an overlap
    /// band: slides a template (T rows from `current`'s center) over `last`'s center
    /// +/- `maxDy` rows and returns the offset with the highest NCC, refined to sub-pixel
    /// via parabolic interpolation around the peak.
    ///
    /// More robust than 1D row-signature correlation on uniform/periodic content (2D features
    /// disambiguate repeated rows), and the bounded search means fast scrolls return a result
    /// instead of nil. `dy > 0` = content scrolled DOWN.
    ///
    /// Performance: precomputes `last`'s luma once (sub-sampled by `xStep` columns) and uses
    /// vDSP for the per-candidate mean/dot/norm, so cost is ~O((H + maxDy) * T * W/xStep) with
    /// vectorized math - keeps it single-digit ms on full retina frames so it doesn't stall the
    /// main-thread capture loop.
    /// - Returns: `(dy, confidence)`; nil if no confident match (peak NCC < 0.5).
    static func detectOverlapDisplacement(last: CGImage, current: CGImage, maxDy: Int) -> (dy: Double, confidence: Double)? {
        let width = last.width
        let height = last.height
        guard width == current.width, height == current.height, height > 20 else { return nil }
        guard let bufA = vImageBuffer(cgImage: last),
              let bufB = vImageBuffer(cgImage: current) else { return nil }
        defer { free(bufA.data); free(bufB.data) }

        let dataA = bufA.data.assumingMemoryBound(to: UInt8.self)
        let dataB = bufB.data.assumingMemoryBound(to: UInt8.self)
        let rowBytesA = bufA.rowBytes
        let rowBytesB = bufB.rowBytes

        let xStep = 4                                  // sub-sample columns for speed
        let spr = width / xStep                        // samples per row
        guard spr > 0 else { return nil }
        let T = min(32, max(8, height / 4))            // template height
        // Template = `current`'s center T rows (center keeps it in the overlap for both
        // downward and upward scrolls, so the sign is recovered).
        let templateStart = max(0, min(height - T, (height - T) / 2))

        // Precompute luma for ALL of `last` and the `current` template (sub-sampled columns).
        var lastLuma = [Float](repeating: 0, count: height * spr)
        var templLuma = [Float](repeating: 0, count: T * spr)
        for y in 0..<height {
            let rowA = dataA.advanced(by: y * rowBytesA)
            let base = y * spr
            for x in 0..<spr {
                let off = (x * xStep) * 4
                lastLuma[base + x] = 0.2126 * Float(rowA[off + 2]) + 0.7152 * Float(rowA[off + 1]) + 0.0722 * Float(rowA[off])
            }
        }
        for r in 0..<T {
            let rowB = dataB.advanced(by: (templateStart + r) * rowBytesB)
            let base = r * spr
            for x in 0..<spr {
                let off = (x * xStep) * 4
                templLuma[base + x] = 0.2126 * Float(rowB[off + 2]) + 0.7152 * Float(rowB[off + 1]) + 0.0722 * Float(rowB[off])
            }
        }

        // Mean-subtract the template; compute its norm.
        let n = vDSP_Length(T * spr)
        var templSum: Float = 0
        vDSP_sve(templLuma, 1, &templSum, n)
        let templMean = templSum / Float(T * spr)
        var negTemplMean = -templMean
        vDSP_vsadd(templLuma, 1, &negTemplMean, &templLuma, 1, n)
        var templNormSq: Float = 0
        vDSP_svesq(templLuma, 1, &templNormSq, n)
        let templNorm = sqrt(templNormSq)
        guard templNorm > 1e-6 else { return nil }   // flat template -> no features

        // Slide the template over `last`'s [templateStart - maxDy, templateStart + maxDy].
        let searchLo = max(0, templateStart - maxDy)
        let searchHi = min(height - T, templateStart + maxDy)
        guard searchHi >= searchLo else { return nil }

        let count = searchHi - searchLo + 1
        var nccCurve = [Float](repeating: 0, count: count)
        var bestNCC: Float = -1
        var bestStart = searchLo
        var candMeaned = [Float](repeating: 0, count: T * spr)

        lastLuma.withUnsafeBufferPointer { lastPtr in
            templLuma.withUnsafeBufferPointer { templPtr in
                candMeaned.withUnsafeMutableBufferPointer { candPtr in
                    let lastBase = lastPtr.baseAddress!
                    let templBase = templPtr.baseAddress!
                    let candBase = candPtr.baseAddress!
                    for start in searchLo...searchHi {
                        let base = start * spr
                        // candidate mean
                        var sum: Float = 0
                        vDSP_sve(lastBase.advanced(by: base), 1, &sum, n)
                        let mean = sum / Float(T * spr)
                        // candMeaned = candidate - mean
                        var negMean = -mean
                        vDSP_vsadd(lastBase.advanced(by: base), 1, &negMean, candBase, 1, n)
                        // dot(candidate-mean, template-mean)
                        var dot: Float = 0
                        vDSP_dotpr(candBase, 1, templBase, 1, &dot, n)
                        // ||candidate-mean||
                        var normSq: Float = 0
                        vDSP_svesq(candBase, 1, &normSq, n)
                        let candNorm = sqrt(normSq)
                        let ncc = (candNorm > 1e-6) ? (dot / (templNorm * candNorm)) : -1
                        nccCurve[start - searchLo] = ncc
                        if ncc > bestNCC {
                            bestNCC = ncc
                            bestStart = start
                        }
                    }
                }
            }
        }

        let confidence = Double(bestNCC)
        guard confidence > 0.5 else {
            logger.debug("OverlapNCC: peak confidence \(String(format: "%.2f", confidence)) below 0.5 (templateStart=\(templateStart) maxDy=\(maxDy))")
            return nil
        }

        // Parabolic sub-pixel refinement around the peak.
        let peakIdx = bestStart - searchLo
        var dySubpixel = Double(bestStart - templateStart)   // signed integer displacement
        if peakIdx > 0 && peakIdx < nccCurve.count - 1 {
            let yL = Double(nccCurve[peakIdx - 1])
            let yC = Double(nccCurve[peakIdx])
            let yR = Double(nccCurve[peakIdx + 1])
            let denom = (yL - 2 * yC + yR)
            if abs(denom) > 1e-6 {
                let delta = 0.5 * (yL - yR) / denom
                if abs(delta) <= 1.0 { dySubpixel += delta }
            }
        }
        logger.debug("OverlapNCC: dy=\(String(format: "%.2f", dySubpixel)) confidence=\(String(format: "%.2f", confidence)) bestStart=\(bestStart) templateStart=\(templateStart)")
        return (dy: dySubpixel, confidence: confidence)
    }

    // MARK: - Full detection pipeline (off-main)

    /// Per-frame displacement detection (NCC -> Vision -> row-correlation -> scroll-event
    /// fallback), plus the `areFramesNearlyIdentical` check. Pure: takes all inputs, returns
    /// the detected dy + updated accumulatedDy + source + lastDy. No `self` access, so it is
    /// safe to run inside a `Task.detached` off the main thread. dy > 0 = scrolled DOWN.
    static func runDetection(
        contentLast: CGImage, contentNew: CGImage,
        frameH: Double, scrollDelta: Double, accumulatedDyIn: Double
    ) -> (dy: Int, source: String, newAccumulatedDy: Double, lastDy: Double)? {
        let framesDiffer = !areFramesNearlyIdentical(contentLast, contentNew)
        let maxDy = min(max(200, Int(abs(scrollDelta) * 0.25) + 20), Int(frameH))
        var accumulated = accumulatedDyIn

        // Step 1: Overlap-band 2D NCC (primary). dy > 0 = downward (no negation needed).
        if let ncc = detectOverlapDisplacement(last: contentLast, current: contentNew, maxDy: maxDy) {
            let acc = accumulated + ncc.dy
            let dy = Int(round(acc))
            if abs(dy) > 0 { return (dy, "ncc", acc, ncc.dy) }
        }

        // Step 2: Vision feature-based registration (fallback if NCC lacks confidence).
        let handler = VNImageRequestHandler(cgImage: contentLast, options: [:])
        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: contentNew)
        do {
            try handler.perform([registrationRequest])
            if let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation {
                // Vision's ty is NEGATIVE for downward scroll, so negate to dy > 0 = downward.
                let rawDy = -Double(observation.alignmentTransform.ty)
                let acc = accumulated + rawDy
                let dy = Int(round(acc))
                if abs(dy) > 0 { return (dy, "vision", acc, rawDy) }
            }
        } catch {
            logger.debug("StableStitch: Vision threw error: \(error.localizedDescription)")
        }

        // Step 3: Row-signature correlation. detectDisplacement returns -D for downward,
        // so negate to match the dy > 0 = downward convention.
        let baseRange = max(200, Int(abs(scrollDelta) * 0.25) + 20)
        let searchRange = min(baseRange, Int(frameH))
        if let corrDy = detectDisplacement(baseline: contentLast, current: contentNew, maxDisplacement: searchRange) {
            let rawDy = -Double(corrDy)
            accumulated += rawDy
            let dy = Int(round(accumulated))
            if abs(dy) > 0 { return (dy, "correlation", accumulated, rawDy) }
        }

        // Step 4: Last-resort fallback - scroll event direction + conservative cap.
        if abs(scrollDelta) > 0.5, framesDiffer {
            let capped = min(640, abs(scrollDelta) * 0.5)
            let guessedDy = scrollDelta > 0 ? capped : -capped
            accumulated += guessedDy
            let dy = Int(round(accumulated))
            if abs(dy) > 0 { return (dy, "scrollEvent", accumulated, guessedDy) }
        }
        return nil
    }

    // MARK: - Content-band detection (chrome exclusion)

    /// Detects the moving content band by direct row comparison of `baseline` vs `current`
    /// (which differ because the user scrolled). Static rows (window chrome: title bar,
    /// toolbar, status bar) are nearly identical between the two frames; moving rows
    /// (content) differ. Returns the bounding box [topY, bottomY] of the moving rows.
    ///
    /// Robust: works for any app (native or Electron), no AX or brightness assumptions.
    /// Call once the first scroll displacement is detected.
    static func detectContentBand(baseline: CGImage, current: CGImage) -> (topY: Int, bottomY: Int)? {
        let width = baseline.width
        let height = baseline.height
        guard width == current.width, height == current.height, height > 20 else { return nil }
        guard let bufA = vImageBuffer(cgImage: baseline),
              let bufB = vImageBuffer(cgImage: current) else { return nil }
        defer { free(bufA.data); free(bufB.data) }
        let dataA = bufA.data.assumingMemoryBound(to: UInt8.self)
        let dataB = bufB.data.assumingMemoryBound(to: UInt8.self)
        let rowBytesA = bufA.rowBytes
        let rowBytesB = bufB.rowBytes

        // Per-row mean absolute difference (sub-sample columns for speed).
        let xStep = 4
        let spr = max(1, width / xStep)
        var rowDiff = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let rowA = dataA.advanced(by: y * rowBytesA)
            let rowB = dataB.advanced(by: y * rowBytesB)
            var sum: Float = 0
            for x in 0..<spr {
                let off = (x * xStep) * 4
                sum += abs(Float(rowA[off]) - Float(rowB[off]))
                sum += abs(Float(rowA[off + 1]) - Float(rowB[off + 1]))
                sum += abs(Float(rowA[off + 2]) - Float(rowB[off + 2]))
            }
            rowDiff[y] = sum / Float(spr * 3)
        }

        // A row is "moving" (content) if its diff is well above noise. Threshold relative
        // to the max row diff so it adapts to strong/weak content contrast.
        let maxDiff = rowDiff.max() ?? 0
        guard maxDiff > 5 else { return nil }   // no meaningful motion between the frames
        let threshold = max(5.0, maxDiff * 0.15)
        var firstMove: Int?
        var lastMove: Int?
        var moveCount = 0
        for y in 0..<height {
            if rowDiff[y] > threshold {
                if firstMove == nil { firstMove = y }
                lastMove = y
                moveCount += 1
            }
        }
        guard let top = firstMove, let bottom = lastMove, moveCount > height / 5 else { return nil }
        logger.debug("ContentBand: top=\(top) bottom=\(bottom) moveCount=\(moveCount) maxDiff=\(String(format: "%.1f", maxDiff))")
        return (topY: top, bottomY: bottom)
    }

    // MARK: - Helpers

    /// Returns true if two frames are essentially identical (mean per-row brightness diff < threshold).
    /// Used to detect when scrolling has stopped (browser at boundary) but scroll events still fire.
    static func areFramesNearlyIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        let width = a.width
        let height = a.height
        guard width == b.width, height == b.height, height > 10 else { return false }

        guard let bufA = vImageBuffer(cgImage: a),
              let bufB = vImageBuffer(cgImage: b) else { return false }
        defer { free(bufA.data); free(bufB.data) }

        let dataA = bufA.data.assumingMemoryBound(to: UInt8.self)
        let dataB = bufB.data.assumingMemoryBound(to: UInt8.self)
        let rowBytesA = bufA.rowBytes
        let rowBytesB = bufB.rowBytes

        // Sample every 4th row for speed (~3ms → <1ms for typical frame)
        let rowStep = 4
        var totalDiff: Float = 0
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: rowStep) {
            let rowA = dataA.advanced(by: y * rowBytesA)
            let rowB = dataB.advanced(by: y * rowBytesB)
            var rowDiff: Float = 0
            for x in 0..<width {
                let off = x * 4
                // Compare grayscale to be color-space agnostic
                let ga = Float(rowA[off]) + Float(rowA[off + 1]) + Float(rowA[off + 2])
                let gb = Float(rowB[off]) + Float(rowB[off + 1]) + Float(rowB[off + 2])
                rowDiff += abs(ga - gb)
            }
            totalDiff += rowDiff / Float(width * 3)
            sampleCount += 1
        }

        let avgDiff = totalDiff / Float(sampleCount)
        return avgDiff < 1.0
    }

    private static func vImageBuffer(cgImage: CGImage) -> vImage_Buffer? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        var buffer = vImage_Buffer()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        
        return buffer
    }
    
    private static func computeMSE(buffer1: vImage_Buffer, row1: Int, buffer2: vImage_Buffer, row2: Int, width: Int, temp1: inout [Float], temp2: inout [Float], temp3: inout [Float]) -> Float {
        let p1 = buffer1.data.advanced(by: row1 * buffer1.rowBytes).assumingMemoryBound(to: UInt8.self)
        let p2 = buffer2.data.advanced(by: row2 * buffer2.rowBytes).assumingMemoryBound(to: UInt8.self)
        
        let count = width * 4
        
        // Convert to float
        vDSP_vfltu8(p1, 1, &temp1, 1, vDSP_Length(count))
        vDSP_vfltu8(p2, 1, &temp2, 1, vDSP_Length(count))
        
        // Scale to 0..1
        var scale: Float = 1.0 / 255.0
        vDSP_vsmul(temp1, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vsmul(temp2, 1, &scale, &temp2, 1, vDSP_Length(count))
        
        // Difference
        vDSP_vsub(temp1, 1, temp2, 1, &temp3, 1, vDSP_Length(count))
        
        // Square and sum
        // Optimization: Use vDSP_vsq for squaring. Note that vDSP_vsq was used in the previous logic.
        // Let's use 3 buffers in the call.
        vDSP_vsq(temp3, 1, &temp3, 1, vDSP_Length(count)) // (a - b)^2
        
        var sum: Float = 0
        vDSP_sve(temp3, 1, &sum, vDSP_Length(count))
        
        return sum / Float(count)
    }
}
