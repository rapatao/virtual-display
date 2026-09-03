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

    private struct Entry {
        let ref: EventHotKeyRef?
        let owner: Owner
        let label: String
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    /// Shortcuts another app already holds. Kept so the diagnostics report can say so:
    /// a shortcut that silently does nothing is otherwise unanswerable.
    private var refused: [String] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    @discardableResult
    public func register(keyCode: Int,
                         modifiers: UInt32 = HotKeyCenter.defaultModifiers,
                         owner: Owner = .app,
                         label: String = "",
                         handler: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x56_44_49_53), id: id)   // 'VDIS'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if !label.isEmpty { refused.append(label) }
            return false
        }

        entries[id] = Entry(ref: ref, owner: owner, label: label, handler: handler)
        return true
    }

    /// For the diagnostics report: what is live, and what another app took.
    public func summary() -> [String] {
        let live = entries.values.map(\.label).filter { !$0.isEmpty }.sorted()
        return live.map { "\($0): active" }
            + refused.sorted().map { "\($0): TAKEN by another app" }
    }

    /// Hands the key back to the system, so reloading a plugin that binds a different
    /// shortcut does not leave the old one live for the rest of the session.
    public func unregister(owner: Owner) {
        for (id, entry) in entries where entry.owner == owner {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
            entries[id] = nil
        }
        if owner == .plugin { refused = [] }   // a reload re-reports its own failures
    }

    fileprivate func fire(_ id: UInt32) {
        entries[id]?.handler()
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
