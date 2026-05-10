import Vision
import CoreGraphics
import AppKit

enum StitchingPhase {
    case baseline
    case motionDetection
    case stableStitching
}

class StitchingEngine {
    internal var baselineFrame: CGImage?
    internal var lastFrame: CGImage?
    internal var phase: StitchingPhase = .baseline
    
    // Original frame dimensions
    internal var frameWidth: Int = 0
    internal var frameHeight: Int = 0
    
    // The exact verified scrolling area bounds (relative to the frame)
    internal var finalCropRect: CGRect?

    // Persistent buffer context
    internal var bufferContext: CGContext?
    internal let bufferMaxHeight: Int = 20000

    // Virtual document space
    internal let initialY: Double = 10000
    internal var minY: Double = 10000
    internal var maxY: Double = 10000
    internal var currentOffset: Double = 10000

    var lastDy: Double = 0
    private var accumulatedDy: Double = 0
    private var frameCount = 0

    func reset() {
        bufferContext = nil
        baselineFrame = nil
        lastFrame = nil
        phase = .baseline
        frameWidth = 0
        frameHeight = 0
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
        print("DEBUG: addFrame phase=\(phase) width=\(newFrame.width)")
        
        switch phase {
        case .baseline:
            self.frameWidth = newFrame.width
            self.frameHeight = newFrame.height
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
                        self.finalCropRect = CGRect(x: 0, y: CGFloat(bounds.topY), width: CGFloat(frameW), height: CGFloat(bounds.bottomY - bounds.topY + 1))
                        
                        // Retrospective: draw the baseline frame cropped to exactly the content rect
                        if let crop = self.finalCropRect,
                           let croppedBaseline = baseline.cropping(to: crop) {
                            
                            self.minY = initialY
                            self.currentOffset = initialY
                            
                            // Draw first chunk of scrolling content into the buffer
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
            
            // Check width consistency
            if newFrame.width != last.width {
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

    internal func setupBuffer(width: Int, height: Int) {
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

    internal func drawInBuffer(_ image: CGImage, at virtualY: Double, height: Double) {
        guard let ctx = bufferContext else { return }
        let destY = Double(bufferMaxHeight) - virtualY - height
        ctx.setBlendMode(.normal)
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(destY), width: CGFloat(image.width), height: CGFloat(height)))
    }

    func finalize() -> CGImage? {
        guard let fullBuffer = bufferContext?.makeImage(), 
              let last = lastFrame, 
              let cropRect = finalCropRect else { 
            return baselineFrame 
        }
        
        if phase != .stableStitching { return lastFrame ?? baselineFrame }

        // 1. Extract the stitched scrolling content
        let contentHeight = Int(ceil(maxY - minY))
        guard contentHeight > 0 else { return lastFrame ?? baselineFrame }
        
        let cropY = CGFloat(Double(bufferMaxHeight) - maxY)
        let bufferCropRect = CGRect(x: 0, y: cropY, width: CGFloat(fullBuffer.width), height: CGFloat(contentHeight))
        guard let stitchedImage = fullBuffer.cropping(to: bufferCropRect) else { return lastFrame ?? baselineFrame }
        
        // 2. Extract Chrome from LAST frame (as decided in brainstorming)
        let headerHeight = Int(cropRect.minY)
        let footerY = Int(cropRect.maxY)
        let footerHeight = Int(last.height) - footerY
        
        // 3. Composite everything
        let totalHeight = headerHeight + contentHeight + max(0, footerHeight)
        let width = last.width
        
        guard let finalContext = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return stitchedImage }
        
        finalContext.setFillColor(NSColor.white.cgColor)
        finalContext.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        
        // Coordinate System: CoreGraphics bottom-left
        // [Header] top
        // [Stitched] mid
        // [Footer] bottom (y=0)
        
        // Draw Footer
        if footerHeight > 0 {
            let footerSourceRect = CGRect(x: 0, y: CGFloat(footerY), width: CGFloat(width), height: CGFloat(footerHeight))
            if let footerImg = last.cropping(to: footerSourceRect) {
                finalContext.draw(footerImg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(footerHeight)))
            }
        }
        
        // Draw Stitched Content
        let stitchedY = CGFloat(max(0, footerHeight))
        finalContext.draw(stitchedImage, in: CGRect(x: 0, y: stitchedY, width: CGFloat(width), height: CGFloat(contentHeight)))
        
        // Draw Header
        if headerHeight > 0 {
            let headerSourceRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(headerHeight))
            if let headerImg = last.cropping(to: headerSourceRect) {
                let headerY = stitchedY + CGFloat(contentHeight)
                finalContext.draw(headerImg, in: CGRect(x: 0, y: headerY, width: CGFloat(width), height: CGFloat(headerHeight)))
            }
        }
        
        return finalContext.makeImage()
    }
}
