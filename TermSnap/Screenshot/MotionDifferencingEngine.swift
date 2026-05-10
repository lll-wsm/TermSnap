import Accelerate
import CoreGraphics
import Foundation

struct MotionDifferencingEngine {
    
    /// Detects the dynamic content boundary by comparing a baseline frame with a new frame that has moved by `dy`.
    /// - Parameters:
    ///   - baseline: The initial frame.
    ///   - current: The current frame after scrolling.
    ///   - dy: The vertical displacement in pixels. Positive means content moved UP relative to the window (i.e. user scrolled DOWN).
    ///   - hintRect: Optional initial rect from Accessibility.
    /// - Returns: The precise (topY, bottomY) of the scrolling content area, or nil if detection fails.
    static func detectContentRect(baseline: CGImage, current: CGImage, dy: Int, hintRect: CGRect? = nil) -> (topY: Int, bottomY: Int)? {
        guard dy != 0 else { return nil }
        
        let width = baseline.width
        let height = baseline.height
        guard width == current.width, height == current.height else { return nil }
        
        guard let baseBuffer = vImageBuffer(cgImage: baseline),
              let currBuffer = vImageBuffer(cgImage: current) else {
            return nil
        }
        
        defer {
            free(baseBuffer.data)
            free(currBuffer.data)
        }
        
        // Configuration
        let tolerance: Float = 0.05 // 5% MSE tolerance
        var isContent = [Bool](repeating: false, count: height)
        
        let absDy = abs(dy)
        
        // Reusable buffers for MSE calculation to avoid row-level allocations
        let floatCount = width * 4
        var bufferA = [Float](repeating: 0, count: floatCount)
        var bufferB = [Float](repeating: 0, count: floatCount)
        var bufferC = [Float](repeating: 0, count: floatCount)
        
        // Process row by row
        for y in 0..<height {
            // If the shifted row is out of bounds, we can't test it for motion.
            // But we can test if it's static.
            let shiftedY = dy > 0 ? y + absDy : y - absDy
            
            let staticError = computeMSE(buffer1: currBuffer, row1: y, buffer2: baseBuffer, row2: y, width: width, temp1: &bufferA, temp2: &bufferB, temp3: &bufferC)
            let isStatic = staticError < tolerance
            
            if shiftedY >= 0 && shiftedY < height {
                let movingError = computeMSE(buffer1: currBuffer, row1: y, buffer2: baseBuffer, row2: shiftedY, width: width, temp1: &bufferA, temp2: &bufferB, temp3: &bufferC)
                let isMoving = movingError < tolerance
                
                // If it matches the shifted row better than the static row, it's content
                if isMoving && !isStatic {
                    isContent[y] = true
                }
            } else {
                // Out of bounds for motion check. If it's not static, it's probably new content appearing.
                if !isStatic {
                    isContent[y] = true
                }
            }
        }
        
        // Find longest contiguous block of true
        var maxLen = 0
        var maxStart = 0
        var currentLen = 0
        var currentStart = 0
        
        for y in 0..<height {
            if isContent[y] {
                if currentLen == 0 { currentStart = y }
                currentLen += 1
            } else {
                if currentLen > maxLen {
                    maxLen = currentLen
                    maxStart = currentStart
                }
                currentLen = 0
            }
        }
        if currentLen > maxLen {
            maxLen = currentLen
            maxStart = currentStart
        }
        
        // If we found a substantial block (e.g. > 50 pixels)
        if maxLen > 50 {
            return (topY: maxStart, bottomY: maxStart + maxLen - 1)
        }
        
        return nil
    }
    
    // MARK: - Helpers
    
    private static func vImageBuffer(cgImage: CGImage) -> vImage_Buffer? {
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var buffer = vImage_Buffer()
        let err = vImageBuffer_InitWithCGImage(&buffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        return buffer
    }
    
    private static func computeMSE(buffer1: vImage_Buffer, row1: Int, buffer2: vImage_Buffer, row2: Int, width: Int, temp1: inout [Float], temp2: inout [Float], temp3: inout [Float]) -> Float {
        // Fast MSE using vDSP on 8-bit ARGB data treated as floats
        let bytesPerRow1 = buffer1.rowBytes
        let bytesPerRow2 = buffer2.rowBytes
        
        let ptr1 = buffer1.data.advanced(by: row1 * bytesPerRow1).assumingMemoryBound(to: UInt8.self)
        let ptr2 = buffer2.data.advanced(by: row2 * bytesPerRow2).assumingMemoryBound(to: UInt8.self)
        
        // Convert to float arrays for vDSP
        let count = width * 4 // 4 channels
        
        vDSP_vfltu8(ptr1, 1, &temp1, 1, vDSP_Length(count))
        vDSP_vfltu8(ptr2, 1, &temp2, 1, vDSP_Length(count))
        
        // Normalize to 0.0 - 1.0
        var divisor: Float = 255.0
        vDSP_vsdiv(temp1, 1, &divisor, &temp1, 1, vDSP_Length(count))
        vDSP_vsdiv(temp2, 1, &divisor, &temp2, 1, vDSP_Length(count))
        
        // Calculate MSE: sum((a - b)^2) / count
        vDSP_vsub(temp2, 1, temp1, 1, &temp3, 1, vDSP_Length(count)) // a - b
        
        // We reuse temp2 for squares to save one more buffer if we wanted, 
        // but for clarity we used 3 buffers in the call.
        vDSP_vsq(temp3, 1, &temp3, 1, vDSP_Length(count)) // (a - b)^2
        
        var sum: Float = 0
        vDSP_sve(temp3, 1, &sum, vDSP_Length(count))
        
        return sum / Float(count)
    }
}
