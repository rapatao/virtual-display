import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts via Carbon's `RegisterEventHotKey`.
///
/// Deliberately not an `NSEvent` global monitor: that requires Accessibility permission,
/// and this does not. Adding a shortcut is one `register` call.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    /// Deep enough to avoid colliding with anything common.
    public static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    @discardableResult
    public func register(keyCode: Int,
                         modifiers: UInt32 = HotKeyCenter.defaultModifiers,
                         handler: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x56_44_49_53), id: id)   // 'VDIS'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }

        handlers[id] = handler
        refs.append(ref)
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

/// Must be a free function: Carbon takes a C function pointer, which cannot capture self.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ context: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let raw = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(raw) }
    }
    return noErr
}
