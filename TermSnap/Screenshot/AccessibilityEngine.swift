import Cocoa
import ApplicationServices

class AccessibilityEngine {
    
    /// Checks if the app is trusted for Accessibility.
    /// - Parameter prompt: If true, the system will prompt the user to grant access if currently untrusted.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// Attempts to find an AXScrollArea at the given global screen coordinate.
    /// - Parameter point: The global Top-Left origin point to inspect.
    /// - Returns: The global frame of the AXScrollArea, or nil if not found or untrusted.
    static func findScrollArea(at point: CGPoint) -> CGRect? {
        guard isTrusted(prompt: false) else { return nil }
        
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPoint: AXUIElement?
        
        let err = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &elementAtPoint)
        guard err == .success, var currentElement = elementAtPoint else { return nil }
        
        // Traverse up the accessibility tree to find a scroll area
        var maxDepth = 20
        while maxDepth > 0 {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &role) == .success,
               let roleString = role as? String,
               roleString == kAXScrollAreaRole {
                
                // Found scroll area, get its position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                
                let posErr = AXUIElementCopyAttributeValue(currentElement, kAXPositionAttribute as CFString, &positionRef)
                let sizeErr = AXUIElementCopyAttributeValue(currentElement, kAXSizeAttribute as CFString, &sizeRef)
                
                if posErr == .success, sizeErr == .success {
                    var axPosition = CGPoint.zero
                    var axSize = CGSize.zero
                    
                    AXValueGetValue(positionRef as! AXValue, .cgPoint, &axPosition)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)
                    
                    return CGRect(origin: axPosition, size: axSize)
                }
            }
            
            // Move to parent
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent) == .success,
               let parentElement = parent {
                currentElement = parentElement as! AXUIElement
            } else {
                break // No parent
            }
            maxDepth -= 1
        }
        
        return nil
    }
}
