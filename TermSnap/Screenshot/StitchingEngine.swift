import Vision
import CoreGraphics
import AppKit

class StitchingEngine {
    private var lastFrame: CGImage?
    
    // Persistent buffer context
    private var bufferContext: CGContext?
    private let bufferMaxHeight: Int = 20000
    
    // Virtual document space
    private let initialY: Double = 10000 
    private var minY: Double = 10000
    private var maxY: Double = 10000
    private var currentOffset: Double = 10000
    
    var lastDy: Double = 0
    private var frameCount = 0

    func reset() {
        bufferContext = nil
        lastFrame = nil
        minY = initialY
        maxY = initialY
        currentOffset = initialY
        lastDy = 0
        frameCount = 0
    }

    /// Processes a new frame. Returns the used portion of the large buffer.
    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        guard let last = lastFrame else {
            setupBuffer(width: newFrame.width, height: bufferMaxHeight)
            drawInBuffer(newFrame, at: initialY, height: Double(newFrame.height))
            
            lastFrame = newFrame
            minY = initialY
            maxY = initialY + Double(newFrame.height)
            currentOffset = initialY
            return finalize()
        }

        let handler = VNImageRequestHandler(cgImage: last, options: [:])
        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
        
        do {
            try handler.perform([registrationRequest])
            guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                return finalize()
            }

            let transform = observation.alignmentTransform
            // Document says: transform.ty is ALREADY in pixels.
            // dy = -transform.ty (dy > 0 means downward scroll)
            let dy = -Double(transform.ty)
            self.lastDy = dy
            frameCount += 1

            // Noise filter
            if abs(dy) < 1.0 {
                return finalize()
            }
            // Error filter
            if abs(dy) > Double(newFrame.height) {
                lastFrame = newFrame
                return finalize()
            }

            currentOffset += dy
            let frameH = Double(newFrame.height)
            let frameW = Double(newFrame.width)

            if dy > 0 {
                // DOWNWARD SCROLL: Only draw the bottom 'dy' pixels (new content)
                let cropRect = CGRect(x: 0, y: frameH - dy, width: frameW, height: dy)
                if let slice = newFrame.cropping(to: cropRect) {
                    // Draw at the bottom of the previous content
                    let virtualY = currentOffset + frameH - dy
                    drawInBuffer(slice, at: virtualY, height: dy)
                }
            } else {
                // UPWARD SCROLL: Draw the entire frame
                drawInBuffer(newFrame, at: currentOffset, height: frameH)
            }
            
            // Update bounds
            minY = min(minY, currentOffset)
            maxY = max(maxY, currentOffset + frameH)
            
            lastFrame = newFrame
            return finalize()

        } catch {
            NSLog("TermSnap: Vision error: \(error)")
        }

        return finalize()
    }

    private func setupBuffer(width: Int, height: Int) {
        bufferContext = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        bufferContext?.setFillColor(NSColor.white.cgColor)
        bufferContext?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func drawInBuffer(_ image: CGImage, at virtualY: Double, height: Double) {
        guard let ctx = bufferContext else { return }
        // destY = bufferMaxHeight - virtualY - imageHeight
        let destY = Double(bufferMaxHeight) - virtualY - height
        ctx.setBlendMode(.normal)
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(destY), width: CGFloat(image.width), height: CGFloat(height)))
    }

    func finalize() -> CGImage? {
        guard let fullBuffer = bufferContext?.makeImage() else { return nil }
        let usedHeight = Int(ceil(maxY - minY))
        guard usedHeight > 0 else { return nil }
        
        // cropRect y = minY (Top-Left space)
        let cropRect = CGRect(x: 0, y: CGFloat(minY), width: CGFloat(fullBuffer.width), height: CGFloat(usedHeight))
        return fullBuffer.cropping(to: cropRect)
    }
}
