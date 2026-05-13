import AppKit
import Carbon.HIToolbox

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var action: (() -> Void)?
    
    private init() {}
    
    func register(keyCode: Int, modifiers: UInt, action: @escaping () -> Void) {
        unregister()
        self.action = action
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("SNAP")
        hotKeyID.id = 1
        
        var carbonModifiers: UInt32 = 0
        if modifiers & NSEvent.ModifierFlags.command.rawValue != 0 { carbonModifiers |= UInt32(cmdKey) }
        if modifiers & NSEvent.ModifierFlags.option.rawValue != 0 { carbonModifiers |= UInt32(optionKey) }
        if modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 { carbonModifiers |= UInt32(shiftKey) }
        if modifiers & NSEvent.ModifierFlags.control.rawValue != 0 { carbonModifiers |= UInt32(controlKey) }
        
        // Install event handler if not already installed
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            
            let status = InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(theEvent,
                                              EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID),
                                              nil,
                                              MemoryLayout<EventHotKeyID>.size,
                                              nil,
                                              &hotKeyID)
                
                if status == noErr && hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        GlobalShortcutManager.shared.action?()
                    }
                    return noErr
                }
                
                return OSStatus(eventNotHandledErr)
            }, 1, &eventType, nil, &eventHandlerRef)
            
            if status != noErr {
                print("TermSnap: Failed to install event handler: \(status)")
            }
        }
        
        let status = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        
        if status != noErr {
            print("TermSnap: Failed to register hotkey: \(status)")
        }
    }
    
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        action = nil
    }
}

extension OSType {
    init(_ string: String) {
        var result: UInt32 = 0
        for char in string.utf8 {
            result = (result << 8) + UInt32(char)
        }
        self = result
    }
}
