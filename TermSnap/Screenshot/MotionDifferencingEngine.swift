import Accelerate
import CoreGraphics
import Foundation

struct MotionDifferencingEngine {
    
    /// Detects the dynamic content boundary by comparing a baseline frame with a new frame that has moved by `dy`.
    /// - Parameters:
    ///   - baseline: The initial frame.
    ///   - current: The current frame after scrolling.
    ///   - dy: The vertical displacement (Top-Down: > 0 means scrolled DOWN).
    ///   - hintRect: Optional hint for localizing search.
    static func detectContentRect(baseline: CGImage, current: CGImage, dy: Int, hintRect: CGRect? = nil) -> (topY: Int, bottomY: Int)? {
        guard dy != 0 else { return nil }
        
        let width = baseline.width
        let height = baseline.height
        guard width == current.width, height == current.height else { return nil }
        
        // Use vImage for efficient pixel access
        guard let baseBuffer = vImageBuffer(cgImage: baseline),
              let currBuffer = vImageBuffer(cgImage: current) else { return nil }
        
        defer {
            free(baseBuffer.data)
            free(currBuffer.data)
        }
        
        let count = width * 4
        var bufferA = [Float](repeating: 0, count: count)
        var bufferB = [Float](repeating: 0, count: count)
        var bufferC = [Float](repeating: 0, count: count)
        
        // Track which rows exhibit motion that matches dy
        var isContent = [Bool](repeating: false, count: height)
        let tolerance: Float = 0.05 // 5% MSE tolerance
        
        for y in 0..<height {
            // SHIFT FIX: 
            // In Top-Down, if we scrolled DOWN (dy > 0), the current row 'y' 
            // matched the baseline row 'y - dy'.
            let shiftedY = y - dy
            
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
        
        // Find range of rows with motion
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
        
        // If we found significant total motion (e.g. > 30 pixels total)
        if let start = firstMotionRow, let end = lastMotionRow, totalMotionRows > 30 {
            return (topY: start, bottomY: end)
        }
        
        return nil
    }
    
    // MARK: - Helpers
    
    private static func vImageBuffer(cgImage: CGImage) -> vImage_Buffer? {
        let width = cgImage.width
        let height = cgImage.height
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
