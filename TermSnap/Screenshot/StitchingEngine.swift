import Vision
import CoreGraphics
import AppKit

enum StitchingPhase {
    case baseline
    case motionDetection
    case stableStitching
}

class StitchingEngine {
    private var baselineFrame: CGImage?
    private var lastFrame: CGImage?
    private var phase: StitchingPhase = .baseline
    
    // The exact verified scrolling area bounds
    private var finalCropRect: CGRect?

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
        baselineFrame = nil
        lastFrame = nil
        phase = .baseline
        finalCropRect = nil
        
        minY = initialY
        maxY = initialY
        currentOffset = initialY
        lastDy = 0
        accumulatedDy = 0
        frameCount = 0
    }

    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        let frameH = Double(newFrame.height)
        let frameW = Double(newFrame.width)
        
        switch phase {
        case .baseline:
            setupBuffer(width: newFrame.width, height: bufferMaxHeight)
            baselineFrame = newFrame
            lastFrame = newFrame
            phase = .motionDetection
            return finalize() // Haven't drawn anything yet, will draw baseline once bounds are known
            
        case .motionDetection:
            guard let last = lastFrame, let baseline = baselineFrame else { return finalize() }
            
            // Calculate dy via Vision
            let handler = VNImageRequestHandler(cgImage: last, options: [:])
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
            
            do {
                try handler.perform([registrationRequest])
                guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                    return finalize()
                }
                
                let transform = observation.alignmentTransform
                let rawDy = -Double(transform.ty)
                let dy = Int(round(rawDy))
                
                // Only attempt differencing if we moved a bit
                if abs(dy) >= 2 {
                    if let bounds = MotionDifferencingEngine.detectContentRect(baseline: baseline, current: newFrame, dy: dy) {
                        self.finalCropRect = CGRect(x: 0, y: CGFloat(bounds.topY), width: CGFloat(frameW), height: CGFloat(bounds.bottomY - bounds.topY + 1))
                        
                        // Retrospective: draw the baseline frame cropped to exactly the content rect
                        if let crop = self.finalCropRect, let croppedBaseline = baseline.cropping(to: crop) {
                            self.minY = initialY
                            self.maxY = initialY + Double(crop.height)
                            self.currentOffset = initialY
                            drawInBuffer(croppedBaseline, at: initialY, height: Double(crop.height))
                        }
                        
                        // Transition to stable mode
                        self.phase = .stableStitching
                        
                        // Process the current frame via stable logic
                        self.lastFrame = baseline // reset lastFrame so dy accumulation works correctly next time
                        return await addFrame(newFrame)
                    }
                }
            } catch {
                NSLog("TermSnap: Vision error: \(error)")
            }
            
            lastFrame = newFrame
            return finalize()
            
        case .stableStitching:
            guard let last = lastFrame, let cropRect = finalCropRect else { return finalize() }
            
            let handler = VNImageRequestHandler(cgImage: last, options: [:])
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
            
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

                // Sanity check: if vision lost tracking completely
                if abs(dy) > Int(frameH / 2) {
                    lastFrame = newFrame
                    accumulatedDy = 0
                    return finalize()
                }

                accumulatedDy -= Double(dy)
                currentOffset += Double(dy)

                // The Magic: We just crop the new frame strictly to the content bounds
                // and draw it directly over the existing buffer at the new offset.
                if let croppedNewFrame = newFrame.cropping(to: cropRect) {
                    drawInBuffer(croppedNewFrame, at: currentOffset, height: Double(cropRect.height))
                    
                    minY = min(minY, currentOffset)
                    maxY = max(maxY, currentOffset + Double(cropRect.height))
                }
                
                lastFrame = newFrame
                return finalize()
                
            } catch {
                NSLog("TermSnap: Vision error: \(error)")
            }
            return finalize()
        }
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
        
        // If we haven't determined bounds yet, just return the baseline frame
        guard phase == .stableStitching else { return baselineFrame }
        
        let usedHeight = Int(ceil(maxY - minY))
        guard usedHeight > 0 else { return baselineFrame }

        let cropRect = CGRect(x: 0, y: CGFloat(minY), width: CGFloat(fullBuffer.width), height: CGFloat(usedHeight))
        return fullBuffer.cropping(to: cropRect)
    }
}
