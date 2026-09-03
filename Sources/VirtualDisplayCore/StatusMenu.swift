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
        public var takeScreenshot: () -> Void = {}
        public var toggleRecording: () -> Void = {}
        public var toggleCursor: () -> Void = {}
        public var toggleLoginItem: () -> Void = {}
        public var copyDiagnostics: () -> Void = {}
        public var openSettings: () -> Void = {}
        public var togglePlugins: () -> Void = {}
        public var reloadPlugins: () -> Void = {}
        public var showPluginError: () -> Void = {}
        public init() {}
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let actions: Actions
    private let menu = NSMenu()

    private let accessItem: ActionMenuItem
    private let mirroringItem: ActionMenuItem
    private let pauseItem: ActionMenuItem
    private let editItem: ActionMenuItem
    private let presetItem = NSMenuItem(title: "Region Presets", action: nil, keyEquivalent: "")
    private let screenshotItem: ActionMenuItem
    private let recordItem: ActionMenuItem
    private let cursorItem: ActionMenuItem
    private let loginItem: ActionMenuItem
    private let pluginsItem: ActionMenuItem
    private let reloadItem: ActionMenuItem
    private let errorItem: ActionMenuItem
    /// Items a plugin added, kept so a reload can take them away again.
    private var pluginItems: [NSMenuItem] = []

    public init(actions: Actions, presets: [RegionSize] = RegionSize.presets) {
        self.actions = actions
        accessItem = ActionMenuItem("Allow Screen Recording...", handler: actions.requestAccess)
        mirroringItem = ActionMenuItem("Mirroring", key: "m",
                                       modifiers: [.control, .option, .command],
                                       handler: actions.toggleMirroring)
        pauseItem = ActionMenuItem("Pause", key: "p",
                                   modifiers: [.control, .option, .command],
                                   handler: actions.togglePause)
        editItem = ActionMenuItem("Edit Region", handler: actions.toggleEditRegion)
        screenshotItem = ActionMenuItem("Take Screenshot", key: "s",
                                        modifiers: [.control, .option, .command],
                                        handler: actions.takeScreenshot)
        recordItem = ActionMenuItem("Start Recording", key: "r",
                                    modifiers: [.control, .option, .command],
                                    handler: actions.toggleRecording)
        cursorItem = ActionMenuItem("Show Cursor in Share", handler: actions.toggleCursor)
        loginItem = ActionMenuItem("Launch at Login", handler: actions.toggleLoginItem)
        pluginsItem = ActionMenuItem("Enable Plugins", handler: actions.togglePlugins)
        reloadItem = ActionMenuItem("Reload Plugins", handler: actions.reloadPlugins)
        errorItem = ActionMenuItem("Plugin Error...", handler: actions.showPluginError)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false   // otherwise AppKit overrides our isEnabled flags

        [accessItem, mirroringItem, pauseItem, editItem].forEach(menu.addItem)
        menu.addItem(presetItem)
        menu.addItem(.separator())
        [screenshotItem, recordItem].forEach(menu.addItem)
        menu.addItem(.separator())
        [cursorItem, loginItem].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings...", key: ",", modifiers: [.command],
                                    handler: actions.openSettings))
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy Diagnostics", handler: actions.copyDiagnostics))
        menu.addItem(pluginsItem)
        menu.addItem(reloadItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Virtual Display",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        errorItem.isHidden = true
        setPresets(presets)
    }

    /// Rebuilt rather than built once: the config file and any plugin can add presets,
    /// and a plugin reload has to be able to take them away again.
    public func setPresets(_ presets: [RegionSize]) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(Self.header("Size"))
        for preset in presets {
            submenu.addItem(ActionMenuItem(preset.name) { [actions] in actions.applySize(preset) })
        }
        submenu.addItem(.separator())
        submenu.addItem(Self.header("Position"))
        for spot in RegionSpot.allCases {
            submenu.addItem(ActionMenuItem(spot.name) { [actions] in actions.applySpot(spot) })
        }
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Snap to Window Below", handler: actions.snapToWindowBelow))
        presetItem.submenu = submenu
    }

    /// Menu items registered by plugins. They sit in their own section under the presets,
    /// so a reload replaces exactly them and nothing built in.
    public func setPluginItems(_ items: [(title: String, run: () -> Void)]) {
        pluginItems.forEach(menu.removeItem)
        pluginItems = []
        guard !items.isEmpty else { return }

        var index = menu.index(of: presetItem) + 1
        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: index)
        pluginItems.append(separator)
        index += 1
        for item in items {
            let menuItem = ActionMenuItem(item.title, handler: item.run)
            menu.insertItem(menuItem, at: index)
            pluginItems.append(menuItem)
            index += 1
        }
    }

    /// Shown only when a plugin actually failed; clicking it explains what went wrong.
    public func setPluginError(_ message: String?) {
        errorItem.isHidden = message == nil
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
        // Both grab the output window, so both need it on screen.
        screenshotItem.isEnabled = state.canCaptureOutput
        recordItem.isEnabled = state.canCaptureOutput || state.isRecording
        recordItem.title = state.isRecording ? "Stop Recording" : "Start Recording"
        pluginsItem.isEnabled = true
        pluginsItem.state = state.arePluginsEnabled ? .on : .off
        // Nothing to reload while plugins are off, and offering it would suggest there is.
        reloadItem.isEnabled = state.arePluginsEnabled
        cursorItem.isEnabled = true
        cursorItem.state = state.showsCursor ? .on : .off
        loginItem.isEnabled = true
        loginItem.state = state.isLoginItemEnabled ? .on : .off
    }

    private static func icon(for state: AppState) -> NSImage? {
        let symbol: String
        if !state.hasScreenRecordingAccess { symbol = "exclamationmark.triangle" }
        // Recording outranks pause in the icon: it is the state you must not forget about.
        else if state.isRecording { symbol = "record.circle" }
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
