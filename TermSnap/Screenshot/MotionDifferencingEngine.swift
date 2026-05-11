import Accelerate
import CoreGraphics
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.lll.TermSnap", category: "MotionDifferencing")

struct MotionDifferencingEngine {
    
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
