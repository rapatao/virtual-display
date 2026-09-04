import AppKit
import Carbon.HIToolbox

/// Wires the pieces together and owns `AppState`.
///
/// Every action mutates state and calls `render()`. Nothing else decides what is visible,
/// which is what keeps the enable / pause / revoke / failure paths from disagreeing.
@MainActor
public final class AppCoordinator: NSObject, NSApplicationDelegate {

    private var state = AppState()

    /// Every action lives here by name, so the menu, the hot keys and the URL scheme all
    /// drive the same code path.
    public let commands = CommandCenter()

    private var config = Config()
    /// Built-in presets plus whatever the config file and plugins added.
    private var presets: [RegionSize] = RegionSize.presets
    /// Presets a plugin added, kept apart so re-reading the config file does not drop them
    /// and unloading plugins does.
    private var pluginPresets: [RegionSize] = []

    private let regionWindow = RegionWindow()
    private let outputWindow = OutputWindow()
    private var capture: CaptureController!
    private var menu: StatusMenu!

    public override init() {
        super.init()

        capture = CaptureController(
            source: CaptureController.Source(
                regionFrame: { [regionWindow] in regionWindow.frame },
                regionScreen: { [regionWindow] in regionWindow.screen },
                excludedWindowNumbers: { [regionWindow, outputWindow] in
                    [regionWindow.windowNumber, outputWindow.windowNumber]
                }),
            sink: outputWindow.sink)

        capture.onFailure = { [weak self] error in self?.captureFailed(error) }
        // The recording stream died on its own; the menu must stop claiming to record.
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            state.isRecording = false
            render()
            report(error)
        }
        regionWindow.onFrameChanged = { [weak self] in
            guard let self else { return }
            capture.regionChanged()
            let f = regionWindow.frame
            lua.emit("region_moved", ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height])
        }
        regionWindow.onScreenChanged = { [weak self] in self?.capture.screenChanged() }
    }

    // MARK: Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        // Before any preference is read: these only apply where the user has no stored
        // choice of their own.
        if let defaults = config.defaults {
            Preferences.fallbacks.showsCursor = defaults.showsCursor ?? true
            Preferences.fallbacks.isEditingRegion = defaults.editRegion ?? true
        }
        presets = RegionSize.presets + config.regionSizes
        CaptureFiles.screenshotFolder = config.captures?.screenshots
        CaptureFiles.recordingFolder = config.captures?.recordings

        state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        state.isEditingRegion = Preferences.isEditingRegion
        state.showsCursor = Preferences.showsCursor
        state.isLoginItemEnabled = LoginItem.isEnabled
        state.arePluginsEnabled = Preferences.pluginsEnabled
        capture.showsCursor = state.showsCursor

        registerCommands()
        menu = StatusMenu(actions: makeActions(), presets: presets)
        installMainMenu()
        registerHotKeys()
        loadPlugins()
        render()
    }

    /// The menu asks for commands by name like everything else, so a menu item and a
    /// `virtualdisplay://` URL cannot drift apart.
    private func makeActions() -> StatusMenu.Actions {
        var actions = StatusMenu.Actions()
        actions.willOpen = { [weak self] in self?.refreshAccess() }
        actions.requestAccess = { [weak self] in self?.run("request-access") }
        actions.toggleMirroring = { [weak self] in self?.run("toggle-mirroring") }
        actions.togglePause = { [weak self] in self?.run("toggle-pause") }
        actions.toggleEditRegion = { [weak self] in self?.run("toggle-edit-region") }
        actions.applySize = { [weak self] preset in
            self?.run("set-size", ["name": preset.name])
        }
        actions.applySpot = { [weak self] spot in
            self?.run("set-spot", ["name": spot.commandName])
        }
        actions.snapToWindowBelow = { [weak self] in self?.run("snap-to-window-below") }
        actions.takeScreenshot = { [weak self] in self?.run("screenshot") }
        actions.toggleRecording = { [weak self] in self?.run("toggle-recording") }
        actions.toggleCursor = { [weak self] in self?.run("toggle-cursor") }
        actions.toggleLoginItem = { [weak self] in self?.run("toggle-login-item") }
        actions.copyDiagnostics = { [weak self] in self?.run("copy-diagnostics") }
        actions.openSettings = { [weak self] in self?.run("settings") }
        actions.openAbout = { [weak self] in self?.run("settings", ["tab": "about"]) }
        actions.togglePlugins = { [weak self] in self?.run("toggle-plugins") }
        actions.reloadPlugins = { [weak self] in self?.run("reload-plugins") }
        actions.showPluginError = { [weak self] in self?.showPluginErrors() }
        return actions
    }

    /// Fire and forget, for the callers with nowhere to show an error: the menu and the
    /// hot keys. A failure here is a wiring bug, so it is logged rather than swallowed.
    private func run(_ name: String, _ args: [String: String] = [:]) {
        do {
            _ = try commands.perform(name, CommandCenter.Arguments(args))
        } catch {
            NSLog("virtual-display: %@", error.localizedDescription)
            NSSound.beep()
        }
    }

    private func run(url: URL) {
        do {
            _ = try commands.perform(url: url)
        } catch {
            NSLog("virtual-display: %@: %@", url.absoluteString, error.localizedDescription)
            NSSound.beep()
        }
    }

    // MARK: Commands

    private func registerCommands() {
        commands.register("toggle-mirroring", "Start or stop mirroring",
                          action: { [weak self] in self?.toggleMirroring() })
        commands.register("set-mirroring", "Mirroring on or off: on=true|false") { [weak self] args in
            guard let self else { return nil }
            if try args.bool("on") != state.isMirroring { toggleMirroring() }
            return nil
        }
        commands.register("toggle-pause", "Pause or resume the running capture",
                          action: { [weak self] in self?.togglePause() })
        commands.register("set-pause", "Pause on or off: on=true|false") { [weak self] args in
            guard let self else { return nil }
            if try args.bool("on") != state.isPaused { togglePause() }
            return nil
        }
        commands.register("toggle-edit-region", "Show or hide the movable region frame",
                          action: { [weak self] in self?.toggleEditRegion() })
        commands.register("set-edit-region", "Region editing on or off: on=true|false") { [weak self] args in
            guard let self else { return nil }
            setEditing(try args.bool("on"))
            return nil
        }
        commands.register("set-size", "Resize the region: name=<preset>, or width= and height=") { [weak self] args in
            guard let self else { return nil }
            let preset = try size(from: args)
            moveRegion { $0.apply(size: preset) }
            return nil
        }
        commands.register("set-spot", "Move the region to an anchor: name=center|top-left|...") { [weak self] args in
            guard let self else { return nil }
            let raw = try args.string("name")
            guard let spot = RegionSpot(commandName: raw) else {
                throw CommandCenter.Failure.badArgument("name", "no anchor called \"\(raw)\"")
            }
            moveRegion { $0.apply(spot: spot) }
            return nil
        }
        commands.register("set-region", "Place the region exactly: x= y= w= h= (screen points)") { [weak self] args in
            guard let self else { return nil }
            let frame = CGRect(x: try args.double("x"), y: try args.double("y"),
                               width: try args.double("w"), height: try args.double("h"))
            moveRegion { $0.place(frame) }
            return nil
        }
        commands.register("region", "Print the region frame as JSON") { [weak self] _ in
            guard let self else { return nil }
            let f = regionWindow.frame
            return #"{"x":\#(f.minX),"y":\#(f.minY),"w":\#(f.width),"h":\#(f.height)}"#
        }
        commands.register("snap-to-window-below", "Fit the region to the window under it") { [weak self] _ in
            guard let self else { return nil }
            var snapped = false
            moveRegion { snapped = $0.snapToWindowBelow() }
            guard snapped else { throw CommandCenter.Failure.failed("no window under the region") }
            return nil
        }
        commands.register("toggle-cursor", "Show or hide the pointer in the shared window",
                          action: { [weak self] in self?.toggleCursor() })
        commands.register("toggle-login-item", "Launch at login on or off",
                          action: { [weak self] in self?.toggleLoginItem() })
        commands.register("request-access", "Ask for Screen Recording permission",
                          action: { [weak self] in self?.requestAccess() })
        commands.register("copy-diagnostics", "Copy the diagnostics report to the clipboard",
                          action: { [weak self] in self?.copyDiagnostics() })
        commands.register("diagnostics", "Print the diagnostics report") { _ in
            Diagnostics.report() + "\n\nshortcuts:\n"
                + HotKeyCenter.shared.summary().map { "  \($0)" }.joined(separator: "\n")
        }
        commands.register("state", "Print the app state as JSON") { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(state) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        commands.register("commands", "List every command") { [weak self] _ in
            self?.commands.listing()
        }
        commands.register("reload-plugins", "Re-read the Lua plugins from disk",
                          action: { [weak self] in self?.reloadPlugins() })
        commands.register("settings", "Open the settings window: tab=presets|shortcuts|captures|plugins|about") { [weak self] args in
            self?.settings.show(tab: args["tab"])
            return nil
        }
        commands.register("toggle-plugins", "Turn Lua plugins on or off",
                          action: { [weak self] in self?.setPlugins(!(self?.state.arePluginsEnabled ?? false)) })
        commands.register("set-plugins", "Plugins on or off: on=true|false") { [weak self] args in
            guard let self else { return nil }
            setPlugins(try args.bool("on"))
            return nil
        }

        commands.register("set-overlay", "Draw over the shared window: id= and text= or image=, "
                          + "plus x= y= w= h= size= color= background= align= alpha= z=") { [weak self] args in
            guard let self else { return nil }
            let id = try args.string("id")
            outputWindow.overlay.set(id, try OverlayItem(args))
            return nil
        }
        commands.register("clear-overlay", "Remove one overlay: id=") { [weak self] args in
            guard let self else { return nil }
            outputWindow.overlay.set(try args.string("id"), nil)
            return nil
        }
        commands.register("clear-overlays", "Remove every overlay",
                          action: { [weak self] in self?.outputWindow.overlay.removeAll() })

        commands.register("screenshot", "Save a PNG of the shared window: path= (optional)") { [weak self] args in
            guard let self else { return nil }
            let url = try destination(args, fallback: CaptureFiles.screenshot())
            let window = try shareableWindowNumber()
            // The capture itself is async; the caller gets the path it will land at, and
            // plugins get the "screenshot" event when it actually has.
            Task { await self.finishScreenshot(windowNumber: window, to: url) }
            return url.path
        }
        commands.register("start-recording", "Record the shared window: path= (optional)") { [weak self] args in
            guard let self else { return nil }
            guard !state.isRecording else { return recorder.url?.path }
            let url = try destination(args, fallback: CaptureFiles.recording())
            let window = try shareableWindowNumber()
            Task { await self.beginRecording(windowNumber: window, to: url) }
            return url.path
        }
        commands.register("stop-recording", "Stop recording and finalise the file") { [weak self] _ in
            guard let self, state.isRecording else { return nil }
            let path = recorder.url?.path
            Task { await self.endRecording() }
            return path
        }
        commands.register("toggle-recording", "Start or stop recording") { [weak self] args in
            guard let self else { return nil }
            return try commands.perform(state.isRecording ? "stop-recording" : "start-recording", args)
        }
    }

    // MARK: Screenshot and recording

    private let recorder = Recorder()

    /// Both grab the output window, which only exists while mirroring does.
    private func shareableWindowNumber() throws -> Int {
        guard state.canCaptureOutput else { throw CaptureFailure.windowGone }
        return outputWindow.windowNumber
    }

    private func destination(_ args: CommandCenter.Arguments,
                             fallback: @autoclosure () throws -> URL) throws -> URL {
        guard let path = args["path"] else { return try fallback() }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func finishScreenshot(windowNumber: Int, to url: URL) async {
        do {
            _ = try await Screenshot.capture(windowNumber: windowNumber, to: url)
            lua.emit("screenshot", ["path": url.path, "ok": true])
        } catch {
            report(error)
            lua.emit("screenshot", ["path": url.path, "ok": false, "error": error.localizedDescription])
        }
    }

    private func beginRecording(windowNumber: Int, to url: URL) async {
        do {
            try await recorder.start(windowNumber: windowNumber, to: url)
            state.isRecording = true
            render()
            lua.emit("recording", ["on": true, "path": url.path])
        } catch {
            report(error)
        }
    }

    private func endRecording() async {
        let path = recorder.url?.path ?? ""
        do {
            try await recorder.stop()
            lua.emit("recording", ["on": false, "path": path])
        } catch {
            report(error)
            lua.emit("recording", ["on": false, "path": path, "error": error.localizedDescription])
        }
        state.isRecording = false
        render()
    }

    private func report(_ error: Error) {
        NSLog("virtual-display: %@", error.localizedDescription)
        NSSound.beep()
    }

    // MARK: Settings

    private lazy var settings = SettingsWindow(environment: makeSettingsEnvironment())

    private func makeSettingsEnvironment() -> SettingsWindow.Environment {
        var environment = SettingsWindow.Environment()
        environment.config = { [weak self] in self?.config ?? Config() }
        environment.save = { [weak self] config in self?.applyConfig(config) }
        environment.regionSize = { [weak self] in self?.regionWindow.frame.size ?? .zero }
        environment.pluginsEnabled = { [weak self] in self?.state.arePluginsEnabled ?? false }
        environment.setPluginsEnabled = { [weak self] on in self?.setPlugins(on) }
        environment.reloadPlugins = { [weak self] in self?.reloadPlugins() }
        environment.pluginErrors = { [weak self] in self?.lua.errors ?? [] }
        environment.commands = { [weak self] in self?.commands.names ?? [] }
        environment.onVisibilityChanged = { [weak self] open in
            guard let self else { return }
            state.isShowingSettings = open
            render()   // the Dock icon follows from the state, like everything else
        }
        environment.setShortcutsSuspended = { suspended in
            HotKeyCenter.shared.setSuspended(suspended)
        }
        return environment
    }

    /// Saves the file and re-applies everything derived from it, so a change made in the
    /// settings window takes effect without a relaunch: presets, shortcuts, and where
    /// captures are written.
    private func applyConfig(_ new: Config) {
        config = new
        do {
            try config.save()
        } catch {
            report(error)
        }

        presets = RegionSize.presets + config.regionSizes + pluginPresets
        menu?.setPresets(presets)
        CaptureFiles.screenshotFolder = config.captures?.screenshots
        CaptureFiles.recordingFolder = config.captures?.recordings

        // Shortcuts are re-registered wholesale: rebinding one has to release the key it
        // used to hold, and Carbon has no way to edit a registration in place.
        HotKeyCenter.shared.unregister(owner: .app)
        registerHotKeys()
    }

    // MARK: Plugins

    private lazy var lua = LuaRuntime(host: makeLuaHost())
    private var pluginMenuItems: [(title: String, run: () -> Void)] = []

    private func makeLuaHost() -> LuaRuntime.Host {
        var host = LuaRuntime.Host()
        host.perform = { [weak self] name, args in
            guard let self else { return nil }
            return try commands.perform(name, CommandCenter.Arguments(args))
        }
        host.registerCommand = { [weak self] name, body in
            self?.commands.register(name, "plugin command", owner: .plugin, run: body)
        }
        host.addPreset = { [weak self] preset in
            guard let self else { return }
            pluginPresets.append(preset)
            presets.append(preset)
            menu?.setPresets(presets)
        }
        host.addMenuItem = { [weak self] title, run in
            guard let self else { return }
            pluginMenuItems.append((title: title, run: run))
            menu?.setPluginItems(pluginMenuItems)
        }
        host.addHotKey = { spec, run in
            HotKeyCenter.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers,
                                         owner: .plugin, handler: run)
        }
        host.state = { [weak self] in self?.state ?? AppState() }
        host.region = { [weak self] in self?.regionWindow.frame ?? .zero }
        host.windows = { ScreenWindows.list() }
        host.fetch = { request, completion in Fetch.send(request, completion: completion) }
        return host
    }

    private func loadPlugins() {
        guard state.arePluginsEnabled else { return }
        lua.load()
        menu?.setPluginError(lua.errors.first)
    }

    /// Turning them off has to undo everything they did, not merely stop loading them
    /// next time: a shortcut a plugin registered would otherwise stay bound for the rest
    /// of the session.
    private func setPlugins(_ enabled: Bool) {
        state.arePluginsEnabled = enabled
        Preferences.pluginsEnabled = enabled
        if enabled {
            loadPlugins()
        } else {
            tearDownPlugins()
        }
        render()
    }

    /// Everything a plugin registered goes away, so nothing can be left holding a
    /// shortcut or calling into a closed Lua state.
    private func tearDownPlugins() {
        lua.unload()
        commands.removeAll(owner: .plugin)
        HotKeyCenter.shared.unregister(owner: .plugin)
        outputWindow.overlay.removeAll()
        pluginMenuItems = []
        pluginPresets = []
        menu?.setPluginItems([])
        presets = RegionSize.presets + config.regionSizes
        menu?.setPresets(presets)
        menu?.setPluginError(nil)
    }

    private func reloadPlugins() {
        tearDownPlugins()
        loadPlugins()
    }

    private func showPluginErrors() {
        let alert = NSAlert()
        alert.messageText = "A plugin did not load"
        alert.informativeText = lua.errors.joined(separator: "\n\n")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Plugins hear about state changes, not about every render: `render()` runs on every
    /// action, most of which change nothing.
    private func emitStateChanges() {
        defer { lastState = state }
        guard let previous = lastState else { return }   // launch is not a change
        if previous.isMirroring != state.isMirroring {
            lua.emit("mirroring", ["on": state.isMirroring])
        }
        if previous.isPaused != state.isPaused {
            lua.emit("pause", ["on": state.isPaused])
        }
        if previous.isEditingRegion != state.isEditingRegion {
            lua.emit("edit_region", ["on": state.isEditingRegion])
        }
    }

    private var lastState: AppState?

    /// `set-size` takes either a preset name or an explicit size; both end up here.
    private func size(from args: CommandCenter.Arguments) throws -> RegionSize {
        if let name = args["name"] {
            guard let preset = presets.first(where: { $0.matches(name) }) else {
                throw CommandCenter.Failure.badArgument("name", "no preset matching \"\(name)\"")
            }
            return preset
        }
        return RegionSize(name: "custom",
                          size: CGSize(width: try args.double("width"),
                                       height: try args.double("height")))
    }

    /// The URL scheme, declared in Info.plist: `virtualdisplay://set-size?name=1280`.
    /// One `open` call away from Shortcuts, Raycast, a Stream Deck or a shell script.
    public func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(run(url:))
    }

    /// Only ever shown while the activation policy is .regular; an accessory app has no
    /// menu bar of its own. Without this the app owns the menu bar with nothing in it.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Virtual Display",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    /// Config shortcuts are registered first, so binding one of the default combinations
    /// to something else in `config.json` wins: the built-in below then simply fails to
    /// register and that action keeps its menu item.
    ///
    /// What ends up bound is pushed to the menu, so a rebound action shows its new keys
    /// rather than the default it no longer answers to.
    private func registerHotKeys() {
        var bound: [String: KeySpec] = [:]
        defer { menu?.setShortcuts(bound) }
        // Config shortcuts name a command, with arguments in the URL query form:
        // "ctrl-opt-cmd-1": "set-size?width=1280&height=720"
        for (spec, command) in config.hotkeys {
            guard let key = KeySpec(spec) else {
                NSLog("virtual-display: config hotkey \"%@\" is not a shortcut", spec)
                continue
            }
            guard let url = URL(string: "virtualdisplay://\(command)") else {
                NSLog("virtual-display: config hotkey \"%@\" has an unusable command", spec)
                continue
            }
            let registered = HotKeyCenter.shared.register(keyCode: key.keyCode,
                                                          modifiers: key.modifiers,
                                                          label: "\(spec) -> \(command)") { [weak self] in
                self?.run(url: url)
            }
            if registered {
                bound[String(command.prefix(while: { $0 != "?" }))] = key
            } else {
                NSLog("virtual-display: shortcut \"%@\" is already taken by another app", spec)
            }
        }

        // All four share ctrl-opt-cmd, which is deep enough to stay out of the way of
        // both apps and the system's own cmd-shift-3/4/5 screenshot keys.
        let defaults: [(Int, String, String)] = [
            (kVK_ANSI_M, "m", "toggle-mirroring"),
            (kVK_ANSI_P, "p", "toggle-pause"),
            (kVK_ANSI_S, "s", "screenshot"),
            (kVK_ANSI_R, "r", "toggle-recording"),
        ]
        let rebound = config.boundCommands
        for (keyCode, key, command) in defaults where !rebound.contains(command) {
            let registered = HotKeyCenter.shared.register(
                keyCode: keyCode,
                label: "ctrl-opt-cmd-\(key) -> \(command)") { [weak self] in self?.run(command) }
            if registered {
                bound[command] = KeySpec(keyCode: keyCode, modifiers: HotKeyCenter.defaultModifiers)
            }
            // Not an error: either the config rebound it, or another app owns the
            // combination. Both are answerable only if we say so somewhere.
            if !registered {
                NSLog("virtual-display: ctrl-opt-cmd-%@ is unavailable; %@ has no shortcut",
                      key, command)
            }
        }
    }

    // MARK: Rendering

    /// The single place state becomes visible. Window order, activation policy and menu
    /// all follow from `AppState`, never from whoever happened to call an action.
    private func render() {
        emitStateChanges()
        menu?.render(state)

        regionWindow.isEditing = state.regionAcceptsMouse
        setVisible(regionWindow, state.showsRegionWindow)
        // orderFront, never makeKeyAndOrderFront: the output window must not steal focus
        // from whatever you are about to drag into the region.
        setVisible(outputWindow, state.showsOutputWindow)

        let policy: NSApplication.ActivationPolicy = state.wantsDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }

        if state.isCapturing {
            guard !capture.isRunning else { return }
            Task { await startCapture() }
        } else {
            capture.stop()
        }
    }

    private func setVisible(_ window: NSWindow, _ visible: Bool) {
        if visible { window.orderFront(nil) } else { window.orderOut(nil) }
    }

    // MARK: Actions

    private func refreshAccess() {
        lua.emit("menu_will_open")
        state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        state.isLoginItemEnabled = LoginItem.isEnabled
        if !state.hasScreenRecordingAccess { state.isMirroring = false }
        render()
    }

    private func requestAccess() {
        switch ScreenRecordingPermission.request() {
        case .granted, .systemPromptShown:
            state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        case .denied:
            state.hasScreenRecordingAccess = false
            render()
            ScreenRecordingPermission.showDeniedAlert(
                reason: "Screen Recording is currently turned off for this app.")
            return
        }
        render()
    }

    private func toggleMirroring() {
        // Belt and braces: the menu item is already greyed out without access, but this
        // must never turn mirroring on regardless of how it got invoked.
        guard state.hasScreenRecordingAccess || state.isMirroring else {
            ScreenRecordingPermission.showDeniedAlert(
                reason: "Screen Recording is currently turned off for this app.")
            return
        }
        state.isMirroring.toggle()
        if state.isMirroring {
            state.isPaused = false   // a fresh start is never a paused one
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // The window being recorded is about to go away. Finalise rather than lose it.
            stopRecordingIfRunning()
        }
        render()
    }

    private func stopRecordingIfRunning() {
        guard state.isRecording else { return }
        Task { await endRecording() }
    }

    /// An unfinalised .mov is not playable, so quitting waits for the file to close.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.isRecording else { return .terminateNow }
        Task {
            await endRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func togglePause() {
        guard state.canPause else { return }
        state.isPaused.toggle()
        render()
    }

    private func toggleEditRegion() {
        setEditing(!state.isEditingRegion)
        if state.isEditingRegion { NSApp.activate(ignoringOtherApps: true) }
    }

    private func setEditing(_ editing: Bool) {
        state.isEditingRegion = editing
        Preferences.isEditingRegion = editing
        render()
    }

    /// Moving the region with the frame hidden would land it somewhere unseen, so reveal
    /// it first. Edit mode is the state that shows it without mirroring running.
    private func moveRegion(_ move: (RegionWindow) -> Void) {
        if !state.showsRegionWindow { setEditing(true) }
        move(regionWindow)
    }

    private func toggleCursor() {
        state.showsCursor.toggle()
        Preferences.showsCursor = state.showsCursor
        capture.showsCursor = state.showsCursor
        render()
    }

    private func toggleLoginItem() {
        do {
            try LoginItem.toggle()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        state.isLoginItemEnabled = LoginItem.isEnabled
        render()
    }

    private func copyDiagnostics() {
        // The same text the `diagnostics` command prints, shortcuts included: a shortcut
        // another app has taken is one of the things people copy this report to explain.
        let report = (try? commands.perform("diagnostics")) ?? Diagnostics.report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Diagnostics copied to the clipboard"
        alert.informativeText = report
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Capture failures

    private func startCapture() async {
        do {
            try await capture.start()
        } catch {
            captureFailed(error)
        }
    }

    /// Capture refused, or stopped on its own mid-session. Roll the state back so the
    /// menu never claims to be mirroring while nothing is being captured.
    private func captureFailed(_ error: Error) {
        lua.emit("capture_failed", ["error": error.localizedDescription])
        stopRecordingIfRunning()   // the output window is about to close
        state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        state.isMirroring = false
        state.isPaused = false
        render()
        ScreenRecordingPermission.showDeniedAlert(reason: error.localizedDescription)
    }
}
