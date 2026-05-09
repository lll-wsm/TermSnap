import Vision
import CoreGraphics
import AppKit

class StitchingEngine {
    private var baseImage: CGImage?
    private var lastFrame: CGImage?
    private let visionQueue = DispatchQueue(label: "com.lll.TermSnap.vision", qos: .userInteractive)
    
    // Total vertical offset from the top of the base image
    private var currentTotalHeight: CGFloat = 0

    func reset() {
        baseImage = nil
        lastFrame = nil
        currentTotalHeight = 0
    }

    /// Processes a new frame and appends it to the stitched result.
    /// Returns the updated stitched image.
    func addFrame(_ newFrame: CGImage) async -> CGImage? {
        guard let last = lastFrame else {
            baseImage = newFrame
            lastFrame = newFrame
            currentTotalHeight = CGFloat(newFrame.height)
            NSLog("TermSnap: StitchingEngine first frame \(newFrame.width)x\(newFrame.height)")
            return newFrame
        }

        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: newFrame)
        let handler = VNSequenceRequestHandler()

        do {
            try handler.perform([registrationRequest], on: last)

            guard let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else {
                lastFrame = newFrame
                NSLog("TermSnap: StitchingEngine no alignment observation")
                return baseImage
            }

            let transform = observation.alignmentTransform
            // Downward scroll results in negative ty in Y-up coordinate system (Vision/CoreGraphics).
            // We want positive dy for the amount of new content revealed at the bottom.
            let dy = -transform.ty * CGFloat(newFrame.height)
            NSLog("TermSnap: StitchingEngine dy=\(dy) transform.ty=\(transform.ty)")

            if dy <= 1.0 {
                lastFrame = newFrame
                return baseImage
            }

            if let stitched = stitch(base: baseImage!, newFrame: newFrame, dy: dy) {
                baseImage = stitched
                lastFrame = newFrame
                return stitched
            }

        } catch {
            NSLog("TermSnap: Vision error: \(error)")
        }

        return baseImage
    }

    private func stitch(base: CGImage, newFrame: CGImage, dy: CGFloat) -> CGImage? {
        let newContentHeight = Int(round(dy))
        guard newContentHeight > 0 else { return base }

        let totalWidth = base.width
        let totalHeight = base.height + newContentHeight
        
        guard let ctx = CGContext(
            data: nil,
            width: totalWidth, height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: totalWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // CoreGraphics coordinates: (0,0) is bottom-left
        
        // 1. Draw the base image at the top
        // In bottom-left origin, top is at y = newContentHeight
        ctx.draw(base, in: CGRect(x: 0, y: CGFloat(newContentHeight), width: CGFloat(totalWidth), height: CGFloat(base.height)))

        // 2. Draw the new slice at the bottom
        // We need the bottom-most pixels of the new frame.
        // In CGImage.cropping, (0,0) is TOP-left.
        let cropRect = CGRect(x: 0, y: CGFloat(newFrame.height) - CGFloat(newContentHeight), 
                              width: CGFloat(newFrame.width), height: CGFloat(newContentHeight))
        
        if let slice = newFrame.cropping(to: cropRect) {
            ctx.draw(slice, in: CGRect(x: 0, y: 0, width: CGFloat(totalWidth), height: CGFloat(newContentHeight)))
        }

        return ctx.makeImage()
    }
    
    func finalize() -> CGImage? {
        return baseImage
    }
}
