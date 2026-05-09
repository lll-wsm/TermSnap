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
                
                if posErr == .success, sizeErr == .success,
                   let positionRef, let sizeRef,
                   CFGetTypeID(positionRef) == AXValueGetTypeID(),
                   CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                    
                    let posVal = positionRef as! AXValue
                    let sizeVal = sizeRef as! AXValue
                    var axPosition = CGPoint.zero
                    var axSize = CGSize.zero
                    
                    let posSuccess = AXValueGetValue(posVal, .cgPoint, &axPosition)
                    let sizeSuccess = AXValueGetValue(sizeVal, .cgSize, &axSize)
                    
                    if posSuccess && sizeSuccess {
                        var finalRect = CGRect(origin: axPosition, size: axSize)
                        
                        // --- NEW: Subtract Scrollbars ---
                        let scrollBarAttributes = [
                            "AXVerticalScrollBar",
                            "AXHorizontalScrollBar"
                        ]
                        
                        for attr in scrollBarAttributes {
                            var scrollBarRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(currentElement, attr as CFString, &scrollBarRef) == .success,
                               let scrollBarRef = scrollBarRef,
                               CFGetTypeID(scrollBarRef) == AXUIElementGetTypeID() {
                                
                                let scrollBar = scrollBarRef as! AXUIElement
                                
                                var sbPosRef: CFTypeRef?
                                var sbSizeRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(scrollBar, kAXPositionAttribute as CFString, &sbPosRef) == .success,
                                   AXUIElementCopyAttributeValue(scrollBar, kAXSizeAttribute as CFString, &sbSizeRef) == .success,
                                   let sbPosRef = sbPosRef, let sbSizeRef = sbSizeRef,
                                   CFGetTypeID(sbPosRef) == AXValueGetTypeID(),
                                   CFGetTypeID(sbSizeRef) == AXValueGetTypeID() {
                                    
                                    let sbPosVal = sbPosRef as! AXValue
                                    let sbSizeVal = sbSizeRef as! AXValue
                                    
                                    var sbPos = CGPoint.zero
                                    var sbSize = CGSize.zero
                                    AXValueGetValue(sbPosVal, .cgPoint, &sbPos)
                                    AXValueGetValue(sbSizeVal, .cgSize, &sbSize)
                                    
                                    let sbRect = CGRect(origin: sbPos, size: sbSize)
                                    
                                    // If scrollbar is at the edge, subtract it
                                    if sbRect.minX > finalRect.minX + finalRect.width * 0.8 {
                                        // Vertical scrollbar on the right
                                        finalRect.size.width -= sbRect.width
                                    } else if sbRect.minY > finalRect.minY + finalRect.height * 0.8 {
                                        // Horizontal scrollbar at the bottom
                                        finalRect.size.height -= sbRect.height
                                    }
                                }
                            }
                        }
                        
                        // --- NEW: Apply 1px Safety Padding ---
                        return finalRect.insetBy(dx: 1, dy: 1)
                    }
                }
            }
            
            // Move to parent
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parent) == .success,
               let parentRef = parent,
               CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
                currentElement = parentRef as! AXUIElement
            } else {
                break // No parent
            }
            maxDepth -= 1
        }
        
        return nil
    }
}
