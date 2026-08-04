import AppKit
import Carbon.HIToolbox

/// A global hotkey, via Carbon.
///
/// The modern-looking route — `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`
/// — needs Accessibility permission for keyboard events, which is a heavy thing
/// to ask for a shortcut. `RegisterEventHotKey` is old API but needs no
/// permission at all, which is why every launcher on the platform still uses it.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    /// ⌥Space by default: unclaimed by macOS, and reachable without moving your
    /// hand to aim at 185 × 32 points.
    init?(keyCode: UInt32 = UInt32(kVK_Space),
          modifiers: UInt32 = UInt32(optionKey),
          action: @escaping () -> Void) {
        let id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let identifier = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.actions[identifier]?() }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5443), id: id)  // 'NOTC'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            Self.actions[id] = nil
            Log.write("hotkey: registration failed (\(status)) — another app may own ⌥Space")
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
