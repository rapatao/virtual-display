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
        var ref: EventHotKeyRef?
        let keyCode: Int
        let modifiers: UInt32
        let owner: Owner
        let label: String
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    /// Shortcuts another app already holds. Kept so the diagnostics report can say so:
    /// a shortcut that silently does nothing is otherwise unanswerable.
    ///
    /// By owner, and a set: the app's shortcuts are re-registered on every config save, so
    /// a list would grow a duplicate line per keystroke typed in the settings window.
    private var refused: [Owner: Set<String>] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    /// How many times a key has been asked of Carbon. The leak this counts is invisible
    /// otherwise: a second `RegisterEventHotKey` for a combination overwrites the ref we
    /// hold, so nothing can hand the first one back and the shortcut fires twice.
    private(set) var registrationAttempts = 0

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

        // Suspended: remember the binding without taking the key, because resuming
        // registers every entry it holds. Taking it here would leave that first
        // registration live and unreferenced, and the combination would then fire twice.
        // Recording a shortcut in settings saves the config, which re-registers, which is
        // exactly this path.
        guard !isSuspended else {
            entries[id] = Entry(ref: nil, keyCode: keyCode, modifiers: modifiers,
                                owner: owner, label: label, handler: handler)
            return true
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x56_44_49_53), id: id)   // 'VDIS'
        registrationAttempts += 1
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if !label.isEmpty { refused[owner, default: []].insert(label) }
            return false
        }

        entries[id] = Entry(ref: ref, keyCode: keyCode, modifiers: modifiers,
                            owner: owner, label: label, handler: handler)
        return true
    }

    /// For the diagnostics report: what is live, and what another app took.
    public func summary() -> [String] {
        // A nil ref is a key we are not holding: refused, or handed back for a recorder.
        // Reporting those as active is how a shortcut that does nothing reads as fine.
        let live = entries.values.filter { $0.ref != nil }
            .map(\.label).filter { !$0.isEmpty }.sorted()
        return live.map { "\($0): active" }
            + refused.values.flatMap { $0 }.sorted().map { "\($0): TAKEN by another app" }
    }

    /// Hands the key back to the system, so reloading a plugin that binds a different
    /// shortcut does not leave the old one live for the rest of the session.
    public func unregister(owner: Owner) {
        for (id, entry) in entries where entry.owner == owner {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
            entries[id] = nil
        }
        refused[owner] = nil   // whatever re-registers next re-reports its own failures
    }

    /// Hands every shortcut back to the system for as long as something else needs the
    /// keys. A shortcut recorder is the case that needs it: Carbon consumes a registered
    /// combination before any NSEvent monitor sees it, so recording the combination an
    /// action already has would fire that action instead of recording it.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended

        for (id, entry) in entries {
            if suspended {
                if let ref = entry.ref { UnregisterEventHotKey(ref) }
                entries[id]?.ref = nil
            } else {
                var ref: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(signature: OSType(0x56_44_49_53), id: id)
                registrationAttempts += 1
                let status = RegisterEventHotKey(UInt32(entry.keyCode), entry.modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &ref)
                entries[id]?.ref = status == noErr ? ref : nil
                // A shortcut bound while suspended is registered for the first time here,
                // so this is where it finds out the key is already taken.
                if status != noErr, !entry.label.isEmpty {
                    refused[entry.owner, default: []].insert(entry.label)
                }
            }
        }
    }

    private var isSuspended = false

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
