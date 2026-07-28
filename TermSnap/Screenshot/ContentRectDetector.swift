import ApplicationServices
import ScreenCaptureKit
import CoreGraphics
import AppKit

struct ContentRectDetector {

    /// Attempts to detect the content area rect via Accessibility API.
    /// Returns (top, bottom, left, right) in frame-local **pixel** coordinates,
    /// or nil if AX detection is not available.
    static func axContentRect(
        for scWindow: SCWindow,
        display: SCDisplay,
        sourceRect: CGRect,
        scale: CGFloat
    ) -> (top: Int, bottom: Int, left: Int, right: Int)? {

        guard let pid = scWindow.owningApplication?.processID else {
            NSLog("TermSnap: AX — no PID for window")
            return nil
        }

        let app = AXUIElementCreateApplication(pid)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        guard let axRect = queryAXContentRect(
            app: app,
            targetFrame: scWindow.frame,
            primaryScreenHeight: primaryScreenHeight
        ) else {
            return nil
        }

        return convertAXRectToFrameLocal(
            axRect: axRect,
            display: display,
            sourceRect: sourceRect,
            scale: scale,
            primaryScreenHeight: primaryScreenHeight
        )
    }

    /// Attempts to detect the content area rect via Accessibility API.
    /// Returns the rect in **display-local points**, or nil if not found.
    static func axContentRectInPoints(
        for scWindow: SCWindow,
        display: SCDisplay
    ) -> CGRect? {
        guard let pid = scWindow.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        guard let axRect = queryAXContentRect(
            app: app,
            targetFrame: scWindow.frame,
            primaryScreenHeight: primaryScreenHeight
        ) else {
            return nil
        }

        // Convert AX (AppKit global, bottom-left Y-up) → SCK global (top-left Y-down)
        let sckX = axRect.origin.x
        let sckTopY = primaryScreenHeight - (axRect.origin.y + axRect.height)

        // SCK global → display-local points
        let dispX = sckX - display.frame.origin.x
        let dispY = sckTopY - display.frame.origin.y

        return CGRect(x: dispX, y: dispY, width: axRect.width, height: axRect.height)
    }

    // MARK: - AX Query

    private static func queryAXContentRect(
        app: AXUIElement,
        targetFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {

        // Convert SCK target frame (top-left) to AppKit global (bottom-left) for matching
        let targetAXY = primaryScreenHeight - targetFrame.maxY
        let targetAXX = targetFrame.minX

        var windowsCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsCF) == .success,
              let axWindows = windowsCF as? [AXUIElement], !axWindows.isEmpty else {
            NSLog("TermSnap: AX — cannot get windows attribute")
            return nil
        }

        // Find the AX window matching our SCWindow by position
        var matchedWindow: AXUIElement?
        for axWin in axWindows {
            guard let f = axWindowFrame(axWin) else { continue }
            if abs(f.origin.x - targetAXX) <= 10,
               abs(f.origin.y - targetAXY) <= 10,
               abs(f.size.width - targetFrame.width) <= 5,
               abs(f.size.height - targetFrame.height) <= 5 {
                matchedWindow = axWin
                break
            }
        }

        guard let win = matchedWindow else {
            NSLog("TermSnap: AX — no matching window found")
            return nil
        }

        // Search children for a scroll area or text area
        guard let children = axChildren(win) else {
            NSLog("TermSnap: AX — no children")
            return nil
        }

        // Direct children first, then grandchildren
        for child in children {
            if let role = axRole(child),
               (role == kAXScrollAreaRole || role == kAXTextAreaRole),
               let frame = axWindowFrame(child) {
                NSLog("TermSnap: AX — found \(role) at direct child")
                return frame
            }
        }

        // Recurse one level: grandchildren
        for child in children {
            guard let grandChildren = axChildren(child) else { continue }
            for gc in grandChildren {
                if let role = axRole(gc),
                   (role == kAXScrollAreaRole || role == kAXTextAreaRole),
                   let frame = axWindowFrame(gc) {
                    NSLog("TermSnap: AX — found \(role) at grandchild")
                    return frame
                }
            }
        }

        NSLog("TermSnap: AX — no scroll/text area found in children")
        return nil
    }

    // MARK: - AX Helpers

    private static func axWindowFrame(_ element: AXUIElement) -> CGRect? {
        var posCF: CFTypeRef?
        var sizeCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posCF) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeCF) == .success else {
            return nil
        }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posCF as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeCF as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        var roleCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCF) == .success else {
            return nil
        }
        return roleCF as? String
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var childrenCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenCF) == .success else {
            return nil
        }
        return childrenCF as? [AXUIElement]
    }

    // MARK: - Coordinate Conversion

    /// Converts an AX content rect (AppKit global, bottom-left, points) to
    /// frame-local pixel coordinates.
    private static func convertAXRectToFrameLocal(
        axRect: CGRect,
        display: SCDisplay,
        sourceRect: CGRect,
        scale: CGFloat,
        primaryScreenHeight: CGFloat
    ) -> (top: Int, bottom: Int, left: Int, right: Int)? {

        // AX (AppKit global, bottom-left Y-up) → SCK global (top-left Y-down)
        let sckX = axRect.origin.x
        let sckTopY = primaryScreenHeight - (axRect.origin.y + axRect.height)

        // SCK global → display-local
        let dispX = sckX - display.frame.origin.x
        let dispY = sckTopY - display.frame.origin.y

        // Display-local → frame-local (points)
        let framePtX = dispX - sourceRect.origin.x
        let framePtY = dispY - sourceRect.origin.y

        // Points → pixels
        let px = Int(round(framePtX * scale))
        let py = Int(round(framePtY * scale))
        let pw = Int(round(axRect.width * scale))
        let ph = Int(round(axRect.height * scale))

        // Validate bounds against frame pixel dimensions
        let framePxW = Int(sourceRect.width * scale)
        let framePxH = Int(sourceRect.height * scale)

        guard px >= 0, py >= 0,
              px + pw <= framePxW,
              py + ph <= framePxH,
              pw > 10, ph > 10 else {
            NSLog("TermSnap: AX rect validation failed — px=\(px) py=\(py) pw=\(pw) ph=\(ph) frameW=\(framePxW) frameH=\(framePxH)")
            return nil
        }

        let top = py
        let bottom = py + ph - 1
        let left = px
        let right = px + pw - 1

        return (top, bottom, left, right)
    }
}
