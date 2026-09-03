import AppKit
import Carbon.HIToolbox

/// A menu item that calls a closure, so adding one does not mean adding an `@objc`
/// method and a selector to some far-away class.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String,
         key: String = "",
         modifiers: NSEvent.ModifierFlags = [],
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

/// The menu bar item and its menu. Builds once, then `render` pushes `AppState` into it.
/// Nothing here decides anything; every decision belongs to `AppState`.
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {

    /// What the menu can ask for. One field per user-visible action.
    public struct Actions {
        public var willOpen: () -> Void = {}
        public var requestAccess: () -> Void = {}
        public var toggleMirroring: () -> Void = {}
        public var togglePause: () -> Void = {}
        public var toggleEditRegion: () -> Void = {}
        public var applySize: (RegionSize) -> Void = { _ in }
        public var applySpot: (RegionSpot) -> Void = { _ in }
        public var snapToWindowBelow: () -> Void = {}
        public var toggleCursor: () -> Void = {}
        public var toggleLoginItem: () -> Void = {}
        public var copyDiagnostics: () -> Void = {}
        public init() {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let actions: Actions

    private let accessItem: ActionMenuItem
    private let mirroringItem: ActionMenuItem
    private let pauseItem: ActionMenuItem
    private let editItem: ActionMenuItem
    private let presetItem = NSMenuItem(title: "Region Presets", action: nil, keyEquivalent: "")
    private let cursorItem: ActionMenuItem
    private let loginItem: ActionMenuItem

    public init(actions: Actions) {
        self.actions = actions
        accessItem = ActionMenuItem("Allow Screen Recording...", handler: actions.requestAccess)
        mirroringItem = ActionMenuItem("Mirroring", key: "m",
                                       modifiers: [.control, .option, .command],
                                       handler: actions.toggleMirroring)
        pauseItem = ActionMenuItem("Pause", key: "p",
                                   modifiers: [.control, .option, .command],
                                   handler: actions.togglePause)
        editItem = ActionMenuItem("Edit Region", handler: actions.toggleEditRegion)
        cursorItem = ActionMenuItem("Show Cursor in Share", handler: actions.toggleCursor)
        loginItem = ActionMenuItem("Launch at Login", handler: actions.toggleLoginItem)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // otherwise AppKit overrides our isEnabled flags

        [accessItem, mirroringItem, pauseItem, editItem].forEach(menu.addItem)
        presetItem.submenu = buildPresetMenu()
        menu.addItem(presetItem)
        menu.addItem(.separator())
        [cursorItem, loginItem].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy Diagnostics", handler: actions.copyDiagnostics))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Virtual Display",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func buildPresetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(Self.header("Size"))
        for preset in RegionSize.presets {
            menu.addItem(ActionMenuItem(preset.name) { [actions] in actions.applySize(preset) })
        }
        menu.addItem(.separator())
        menu.addItem(Self.header("Position"))
        for spot in RegionSpot.allCases {
            menu.addItem(ActionMenuItem(spot.name) { [actions] in actions.applySpot(spot) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Snap to Window Below", handler: actions.snapToWindowBelow))
        return menu
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Rendering

    public func render(_ state: AppState) {
        statusItem.button?.image = Self.icon(for: state)

        accessItem.isHidden = state.hasScreenRecordingAccess
        mirroringItem.isEnabled = state.canToggleMirroring
        mirroringItem.state = state.isMirroring ? .on : .off
        pauseItem.isEnabled = state.canPause
        pauseItem.state = state.isPaused ? .on : .off
        // Region controls stay live with mirroring off: placing the region is a setup
        // task you do before joining a call, not something gated on capture running.
        editItem.isEnabled = true
        editItem.state = state.isEditingRegion ? .on : .off
        presetItem.isEnabled = true
        cursorItem.isEnabled = true
        cursorItem.state = state.showsCursor ? .on : .off
        loginItem.isEnabled = true
        loginItem.state = state.isLoginItemEnabled ? .on : .off
    }

    private static func icon(for state: AppState) -> NSImage? {
        let symbol: String
        if !state.hasScreenRecordingAccess { symbol = "exclamationmark.triangle" }
        else if state.isPaused && state.isMirroring { symbol = "pause.rectangle" }
        else if state.isMirroring { symbol = "rectangle.on.rectangle" }
        else { symbol = "rectangle.on.rectangle.slash" }
        // Falls back rather than leaving an empty button if a symbol is unavailable.
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "Virtual Display")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Virtual Display")
    }

    /// The menu refreshes on every open, so a grant made or revoked in System Settings
    /// while we were running lands without a restart.
    public func menuWillOpen(_ menu: NSMenu) { actions.willOpen() }
}
