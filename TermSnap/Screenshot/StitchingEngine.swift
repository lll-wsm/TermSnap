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
    private var accumulatedDy: Double = 0
    private var frameCount = 0

    func reset() {
        bufferContext = nil
        lastFrame = nil
        minY = initialY
        maxY = initialY
        currentOffset = initialY
        lastDy = 0
        accumulatedDy = 0
        frameCount = 0
    }

    /// Processes a new frame. Returns the used portion of the large buffer.
    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        let frameH = Double(newFrame.height)
        let frameW = Double(newFrame.width)
        
        guard let last = lastFrame else {
            setupBuffer(width: newFrame.width, height: bufferMaxHeight)
            drawInBuffer(newFrame, at: initialY, height: frameH)
            lastFrame = newFrame
            minY = initialY
            maxY = initialY + frameH
            currentOffset = initialY
            return finalize()
        }

        let handler = VNImageRequestHandler(cgImage: last, options: [:])
        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
        // No regionOfInterest - use full frame for maximum precision

        do {
            try handler.perform([registrationRequest])
            guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                return finalize()
            }

            let transform = observation.alignmentTransform
            let rawDy = -Double(transform.ty)
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

            if dy > 0 {
                // Scroll DOWN: new frame sits higher in the document. Drawing the full
                // frame would place its title bar over previous-frame content, so only
                // draw the non-overlapping bottom portion.
                let extractH = min(dy, newFrame.height)
                let srcY = newFrame.height - extractH
                if let slice = newFrame.cropping(to: CGRect(x: 0, y: srcY, width: Int(frameW), height: extractH)) {
                    drawInBuffer(slice, at: currentOffset + Double(srcY), height: Double(extractH))
                }
            } else {
                // Scroll UP: new frame sits lower in the document. Its title bar is
                // below the previous frame and cannot overwrite it. Full frame is safe.
                drawInBuffer(newFrame, at: currentOffset, height: frameH)
            }

            minY = min(minY, currentOffset)
            maxY = max(maxY, currentOffset + frameH)
            
            lastFrame = newFrame
            return finalize()
        } catch {
            NSLog("TermSnap: Vision error: \(error)")
        }
        return finalize()
    }

    // MARK: - Buffer drawing

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
        let destY = Double(bufferMaxHeight) - virtualY - height
        ctx.setBlendMode(.normal)
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(destY), width: CGFloat(image.width), height: CGFloat(height)))
    }

    func finalize() -> CGImage? {
        guard let fullBuffer = bufferContext?.makeImage() else { return nil }
        let usedHeight = Int(ceil(maxY - minY))
        guard usedHeight > 0 else { return nil }

        let cropRect = CGRect(x: 0, y: CGFloat(minY), width: CGFloat(fullBuffer.width), height: CGFloat(usedHeight))
        return fullBuffer.cropping(to: cropRect)
    }
}
