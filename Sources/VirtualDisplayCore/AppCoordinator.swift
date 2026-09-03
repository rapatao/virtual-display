import AppKit
import Carbon.HIToolbox

/// Wires the pieces together and owns `AppState`.
///
/// Every action mutates state and calls `render()`. Nothing else decides what is visible,
/// which is what keeps the enable / pause / revoke / failure paths from disagreeing.
@MainActor
public final class AppCoordinator: NSObject, NSApplicationDelegate {

    private var state = AppState()

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
        regionWindow.onFrameChanged = { [weak self] in self?.capture.regionChanged() }
        regionWindow.onScreenChanged = { [weak self] in self?.capture.screenChanged() }
    }

    // MARK: Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        state.isEditingRegion = Preferences.isEditingRegion
        state.showsCursor = Preferences.showsCursor
        state.isLoginItemEnabled = LoginItem.isEnabled
        capture.showsCursor = state.showsCursor

        menu = StatusMenu(actions: makeActions())
        installMainMenu()
        registerHotKeys()
        render()
    }

    private func makeActions() -> StatusMenu.Actions {
        var actions = StatusMenu.Actions()
        actions.willOpen = { [weak self] in self?.refreshAccess() }
        actions.requestAccess = { [weak self] in self?.requestAccess() }
        actions.toggleMirroring = { [weak self] in self?.toggleMirroring() }
        actions.togglePause = { [weak self] in self?.togglePause() }
        actions.toggleEditRegion = { [weak self] in self?.toggleEditRegion() }
        actions.applySize = { [weak self] preset in self?.moveRegion { $0.apply(size: preset) } }
        actions.applySpot = { [weak self] spot in self?.moveRegion { $0.apply(spot: spot) } }
        actions.snapToWindowBelow = { [weak self] in
            self?.moveRegion { if !$0.snapToWindowBelow() { NSSound.beep() } }
        }
        actions.toggleCursor = { [weak self] in self?.toggleCursor() }
        actions.toggleLoginItem = { [weak self] in self?.toggleLoginItem() }
        actions.copyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        return actions
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

    private func registerHotKeys() {
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_M) { [weak self] in self?.toggleMirroring() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_P) { [weak self] in self?.togglePause() }
    }

    // MARK: Rendering

    /// The single place state becomes visible. Window order, activation policy and menu
    /// all follow from `AppState`, never from whoever happened to call an action.
    private func render() {
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
        }
        render()
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
        let report = Diagnostics.report()
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
        state.hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
        state.isMirroring = false
        state.isPaused = false
        render()
        ScreenRecordingPermission.showDeniedAlert(reason: error.localizedDescription)
    }
}
