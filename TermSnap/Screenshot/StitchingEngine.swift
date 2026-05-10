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
    private var headerRect: CGRect?
    private var footerRect: CGRect?

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
        headerRect = nil
        footerRect = nil
        
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
            frameCount = 1
            return finalize() // Haven't drawn anything yet, will draw baseline once bounds are known
            
        case .motionDetection:
            guard let last = lastFrame, let baseline = baselineFrame else { return finalize() }
            
            // Calculate dy via Vision
            let handler = VNImageRequestHandler(cgImage: last, options: [:])
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
            
            do {
                try handler.perform([registrationRequest])
                guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                    self.lastFrame = newFrame
                    return finalize()
                }
                
                let transform = observation.alignmentTransform
                let rawDy = -Double(transform.ty)
                self.accumulatedDy += rawDy
                let totalDy = Int(round(self.accumulatedDy))
                
                // Only attempt differencing if we moved significantly from baseline
                if abs(totalDy) >= 5 {
                    if let bounds = MotionDifferencingEngine.detectContentRect(baseline: baseline, current: newFrame, dy: totalDy) {
                        self.headerRect = CGRect(x: 0, y: 0, width: CGFloat(frameW), height: CGFloat(bounds.topY))
                        self.finalCropRect = CGRect(x: 0, y: CGFloat(bounds.topY), width: CGFloat(frameW), height: CGFloat(bounds.bottomY - bounds.topY + 1))
                        let footerHeight = frameH - Double(bounds.bottomY + 1)
                        self.footerRect = CGRect(x: 0, y: CGFloat(bounds.bottomY + 1), width: CGFloat(frameW), height: CGFloat(max(0, footerHeight)))
                        
                        // Retrospective: draw the header and the baseline frame cropped to exactly the content rect
                        if let header = self.headerRect, let crop = self.finalCropRect,
                           let croppedHeader = baseline.cropping(to: header),
                           let croppedBaseline = baseline.cropping(to: crop) {
                            
                            self.minY = initialY
                            self.currentOffset = initialY
                            
                            // Draw static header
                            if header.height > 0 {
                                drawInBuffer(croppedHeader, at: currentOffset, height: Double(header.height))
                                self.currentOffset += Double(header.height)
                            }
                            
                            // Draw first chunk of scrolling content
                            drawInBuffer(croppedBaseline, at: currentOffset, height: Double(crop.height))
                            self.maxY = currentOffset + Double(crop.height)
                        }
                        
                        // Transition to stable mode
                        self.phase = .stableStitching
                        
                        // Process the current frame via stable logic
                        self.lastFrame = baseline // reset lastFrame so dy accumulation works correctly next time
                        self.accumulatedDy = 0 // Reset accumulation for stable tracking
                        return await addFrame(newFrame)
                    }
                }
            } catch {
                // Vision error
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
                // Vision error
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
        guard phase == .stableStitching, let footer = footerRect, let last = lastFrame else {
            return baselineFrame
        }
        
        let usedHeight = Int(ceil(maxY - minY))
        guard usedHeight > 0 else { return baselineFrame }

        let bufferCropRect = CGRect(x: 0, y: CGFloat(minY), width: CGFloat(fullBuffer.width), height: CGFloat(usedHeight))
        guard let croppedBuffer = fullBuffer.cropping(to: bufferCropRect) else { return baselineFrame }
        
        if footer.height <= 0 { return croppedBuffer }
        
        // Create final context incorporating the footer
        let finalWidth = fullBuffer.width
        let finalHeight = usedHeight + Int(footer.height)
        
        guard let finalContext = CGContext(
            data: nil,
            width: finalWidth, height: finalHeight,
            bitsPerComponent: 8,
            bytesPerRow: finalWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return croppedBuffer }
        
        finalContext.setFillColor(NSColor.white.cgColor)
        finalContext.fill(CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight))
        
        // Draw footer at bottom (y = 0 in CoreGraphics bottom-left coordinates)
        if let croppedFooter = last.cropping(to: footer) {
            finalContext.draw(croppedFooter, in: CGRect(x: 0, y: 0, width: CGFloat(finalWidth), height: footer.height))
        }
        
        // Draw scroll content above footer (y = footer.height)
        finalContext.draw(croppedBuffer, in: CGRect(x: 0, y: footer.height, width: CGFloat(finalWidth), height: CGFloat(usedHeight)))
        
        return finalContext.makeImage() ?? croppedBuffer
    }
}
