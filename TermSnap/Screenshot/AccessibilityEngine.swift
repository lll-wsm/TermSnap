import Cocoa
import ApplicationServices

class AccessibilityEngine {
    
    /// Checks if the app is trusted for Accessibility.
    /// - Parameter prompt: If true, the system will prompt the user to grant access if currently untrusted.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
