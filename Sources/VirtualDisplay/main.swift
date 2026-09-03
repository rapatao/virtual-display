import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - Geometry

enum Geometry {
    /// AppKit global space: y-up, origin at the PRIMARY screen's bottom-left.
    /// CG display space:    y-down, origin at the PRIMARY screen's top-left.
    /// `SCStreamConfiguration.sourceRect` wants points relative to the captured
    /// display's own origin, so we flip and then subtract that origin.
    static func sourceRect(appKitRect r: CGRect,
                           primaryHeight: CGFloat,
                           displayOrigin: CGPoint) -> CGRect {
        CGRect(x: r.minX - displayOrigin.x,
               y: primaryHeight - r.maxY - displayOrigin.y,
               width: r.width,
               height: r.height)
    }

    /// Keeps a proposed region frame fully on the given screen area, shrinking it first
    /// if it is larger than the screen so the origin clamp below can never go negative.
    static func clamp(_ proposed: CGRect, into visible: CGRect) -> CGRect {
        var f = proposed
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    static func selftest() {
        // Single 1440pt-tall primary display, region 200pt up from the bottom.
        let a = sourceRect(appKitRect: CGRect(x: 100, y: 200, width: 960, height: 540),
                           primaryHeight: 1440,
                           displayOrigin: .zero)
        precondition(a == CGRect(x: 100, y: 700, width: 960, height: 540), "primary flip wrong: \(a)")

        // Region flush to the bottom-left of the primary display.
        let b = sourceRect(appKitRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                           primaryHeight: 1000,
                           displayOrigin: .zero)
        precondition(b == CGRect(x: 0, y: 900, width: 100, height: 100), "bottom-left wrong: \(b)")

        // Secondary display sitting to the LEFT of primary: CG origin has negative x.
        // Region at AppKit x = -1600 is at x = 0 on that display.
        let c = sourceRect(appKitRect: CGRect(x: -1600, y: 400, width: 800, height: 600),
                           primaryHeight: 1440,
                           displayOrigin: CGPoint(x: -1600, y: 0))
        precondition(c == CGRect(x: 0, y: 440, width: 800, height: 600), "left display wrong: \(c)")

        // visibleFrame of a 1920x1080 primary, minus menu bar and Dock.
        let vis = CGRect(x: 0, y: 80, width: 1920, height: 963)

        // Already inside: untouched.
        let inside = CGRect(x: 400, y: 300, width: 960, height: 540)
        precondition(clamp(inside, into: vis) == inside, "in-bounds frame moved: \(clamp(inside, into: vis))")

        // Hanging off the right and bottom: slid back, size kept.
        let off = clamp(CGRect(x: 1800, y: -200, width: 960, height: 540), into: vis)
        precondition(off == CGRect(x: 960, y: 80, width: 960, height: 540), "off-screen clamp wrong: \(off)")

        // Bigger than the screen: shrunk to fit, then pinned to the origin. Without the
        // shrink-first order the origin clamp would produce a negative x.
        let big = clamp(CGRect(x: 500, y: 500, width: 3000, height: 2000), into: vis)
        precondition(big == vis, "oversized clamp wrong: \(big)")

        print("selftest OK")
    }
}

// MARK: - Region overlay view

final class BorderView: NSView {
    var isEditing = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if isEditing {
            // A non-zero alpha is what makes the interior hit-testable, so the whole
            // frame is draggable while editing. Locked mode leaves it fully clear.
            NSColor.white.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
        (isEditing ? NSColor.systemRed : NSColor.systemGreen).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - App

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, SCStreamDelegate, SCStreamOutput {

    private let borderView = BorderView()
    // nonisolated so the capture queue can hand frames straight to it; every actual
    // touch below is already hopped onto the main queue.
    nonisolated(unsafe) private let videoLayer = AVSampleBufferDisplayLayer()
    private let sampleQueue = DispatchQueue(label: "com.rapatao.virtual-display.capture")

    private var stream: SCStream?
    private var config = SCStreamConfiguration()
    private var display: SCDisplay?
    private static let outputVisibleKey = "showOutputWindow"
    private static let editingKey = "editRegion"
    private var isEditing = UserDefaults.standard.object(forKey: App.editingKey) as? Bool ?? true
    // Off at launch: the app comes up as a tray icon only, no windows, no capture.
    private var isEnabled = false
    /// Re-read on every menu open, so revoking access mid-session greys the toggle out.
    private var hasAccess = CGPreflightScreenCaptureAccess()
    /// macOS shows its Screen Recording dialog exactly once per app, ever. There is no
    /// API to ask whether that has happened, so remember it ourselves.
    private static let didRequestKey = "didRequestScreenRecordingAccess"
    private var didRequestAccess = UserDefaults.standard.bool(forKey: App.didRequestKey)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let enabledItem = NSMenuItem(title: "Mirroring", action: #selector(toggleEnabled), keyEquivalent: "")
    private let editItem = NSMenuItem(title: "Edit Region", action: #selector(toggleEdit), keyEquivalent: "")
    private let outputItem = NSMenuItem(title: "Show Output Window", action: #selector(toggleOutput), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Allow Screen Recording...", action: #selector(requestAccess), keyEquivalent: "")
    private let presetItem = NSMenuItem(title: "Region Presets", action: nil, keyEquivalent: "")

    /// Region sizes in points. On a 2x display 960x540 pt is exactly the 1920x1080 px
    /// output canvas, so it mirrors 1:1 with no resampling.
    private static let sizePresets: [(name: String, size: NSSize)] = [
        ("960 x 540  (1:1 on Retina)", NSSize(width: 960, height: 540)),
        ("1280 x 720", NSSize(width: 1280, height: 720)),
        ("1920 x 1080", NSSize(width: 1920, height: 1080)),
        ("Half Screen", .zero),   // .zero means "computed from the screen", see applySize
    ]

    private enum Spot: Int, CaseIterable {
        case center, topLeft, topRight, bottomLeft, bottomRight
        var name: String {
            switch self {
            case .center: return "Center"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    private lazy var regionWindow: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 960, height: 540),
                         styleMask: [.titled, .resizable, .fullSizeContentView],
                         backing: .buffered,
                         defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(button)?.isHidden = true
        }
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 160, height: 90)
        w.contentView = borderView
        // Restore before registering autosave, otherwise AppKit writes the default
        // frame out before the saved one has been read back.
        w.setFrameUsingName("RegionWindow")
        w.setFrameAutosaveName("RegionWindow")
        // Delegate LAST. setFrameUsingName posts NSWindowDidMove synchronously, and any
        // delegate callback reading this lazy var while it is still initializing sends
        // Swift back through the initializer -> unbounded recursion.
        w.delegate = self
        return w
    }()

    private lazy var outputWindow: NSWindow = {
        // No .closable / .miniaturizable: closing or minimising this window kills the
        // Meet share. Disabling from the tray pauses the mirror instead.
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                         styleMask: [.titled, .resizable],
                         backing: .buffered,
                         defer: false)
        // This title is what shows up in the Meet / Zoom window picker.
        w.title = "Virtual Display"
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.isReleasedWhenClosed = false

        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        let host = NSView()
        host.layer = videoLayer      // assign before wantsLayer: makes the view layer-HOSTING
        host.wantsLayer = true
        w.contentView = host
        w.setFrameUsingName("OutputWindow")
        w.setFrameAutosaveName("OutputWindow")
        w.delegate = self   // last, for the same reason as regionWindow above
        return w
    }()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build both windows up front, in a known order, before anything can call back
        // into them. Materialising a lazy NSWindow from inside a window delegate is how
        // the frame-restore recursion happened; doing it here keeps that impossible.
        // Neither is ordered on screen, so the app is still tray-only at launch.
        _ = regionWindow
        _ = outputWindow
        // A hidden output window is invisible to the meeting's window picker, so if it
        // was open last time, bring it back. orderFront, not makeKeyAndOrderFront: it
        // must not steal focus on login.
        if UserDefaults.standard.bool(forKey: Self.outputVisibleKey) {
            outputWindow.orderFront(nil)
        }
        installMainMenu()
        // Permission is checked on first enable so launching never puts a dialog up.
        installStatusItem()
    }

    private func installStatusItem() {
        let menu = NSMenu()

        for item in [accessItem, enabledItem, editItem] {
            item.target = self
            menu.addItem(item)
        }
        presetItem.submenu = buildPresetMenu()
        menu.addItem(presetItem)
        outputItem.target = self
        menu.addItem(outputItem)
        menu.addItem(.separator())
        menu.delegate = self
        menu.autoenablesItems = false   // otherwise AppKit overrides our isEnabled flags

        menu.addItem(NSMenuItem(title: "Quit Virtual Display",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        syncUI()
    }

    /// Chrome and several other conferencing apps build their "share a window" list from
    /// applications that have a Dock presence, so an LSUIElement agent app's windows are
    /// never offered. Become a regular app exactly while the shareable window is on
    /// screen, and go back to tray-only the moment it is hidden.
    private func syncActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = outputWindow.isVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// Only ever shown while the activation policy is .regular; an accessory app has no
    /// menu bar of its own. Without this the app owns the menu bar with nothing in it.
    private func installMainMenu() {
        let appMenu = NSMenu()
        let show = NSMenuItem(title: "Show Output Window", action: #selector(toggleOutput), keyEquivalent: "")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Virtual Display",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    private func buildPresetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(sectionHeader("Size"))
        for (index, preset) in Self.sizePresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(applySize(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Position"))
        for spot in Spot.allCases {
            let item = NSMenuItem(title: spot.name, action: #selector(applySpot(_:)), keyEquivalent: "")
            item.tag = spot.rawValue
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Every programmatic move goes through here so the region can never be parked
    /// off-screen or made bigger than the display it sits on.
    private func setRegionFrame(_ proposed: NSRect) {
        guard let visible = (regionWindow.screen ?? NSScreen.main)?.visibleFrame else { return }
        // Picking a preset with the frame hidden would land it somewhere unseen, so
        // reveal it. Edit mode is the state that shows it without mirroring running.
        if !regionWindow.isVisible { setEditing(true) }
        // setFrame posts didMove/didResize, so refreshSourceRect runs off the delegate.
        regionWindow.setFrame(Geometry.clamp(proposed, into: visible), display: true)
    }

    @objc private func applySize(_ sender: NSMenuItem) {
        let preset = Self.sizePresets[sender.tag]
        var size = preset.size
        if size == .zero, let visible = (regionWindow.screen ?? NSScreen.main)?.visibleFrame {
            size = NSSize(width: visible.width / 2, height: visible.width / 2 * 9 / 16)
        }
        var f = regionWindow.frame
        // Grow downward from the current top edge: resizing around the bottom-left
        // origin would make the frame appear to jump upward.
        f.origin.y = f.maxY - size.height
        f.size = size
        setRegionFrame(f)
    }

    @objc private func applySpot(_ sender: NSMenuItem) {
        guard let spot = Spot(rawValue: sender.tag),
              let visible = (regionWindow.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = regionWindow.frame
        switch spot {
        case .center:
            f.origin = CGPoint(x: visible.midX - f.width / 2, y: visible.midY - f.height / 2)
        case .topLeft:
            f.origin = CGPoint(x: visible.minX, y: visible.maxY - f.height)
        case .topRight:
            f.origin = CGPoint(x: visible.maxX - f.width, y: visible.maxY - f.height)
        case .bottomLeft:
            f.origin = visible.origin
        case .bottomRight:
            f.origin = CGPoint(x: visible.maxX - f.width, y: visible.minY)
        }
        setRegionFrame(f)
    }

    /// Single place that pushes `isEnabled` / `isEditing` out to the icon, the menu
    /// checkmarks, the border colour and the region window's visibility.
    private func syncUI() {
        let symbol: String
        if !hasAccess { symbol = "exclamationmark.triangle" }
        else if isEnabled { symbol = "rectangle.on.rectangle" }
        else { symbol = "rectangle.on.rectangle.slash" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Virtual Display")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Virtual Display")

        // No Screen Recording grant means mirroring is not merely refused on click,
        // it is not offerable: the toggle greys out and a fix-it row takes its place.
        accessItem.isHidden = hasAccess
        enabledItem.isEnabled = hasAccess
        enabledItem.state = isEnabled ? .on : .off
        // Region controls stay live with mirroring off: placing the region is a setup
        // task you do before joining a call, not something gated on capture running.
        editItem.state = isEditing ? .on : .off
        editItem.isEnabled = true
        presetItem.isEnabled = true
        // The output window is never shown or hidden as a side effect of anything else;
        // only toggleOutput() moves it. Enabling mirroring must not pop it up.
        outputItem.state = outputWindow.isVisible ? .on : .off
        syncActivationPolicy()

        borderView.isEditing = isEditing
        // Locked = click-through, so the window you dragged into the region stays usable.
        regionWindow.ignoresMouseEvents = !isEditing
        // Visible while editing (you are placing it) or while mirroring (it marks what
        // is being shared). Neither: it has nothing to say, so it goes away.
        if isEnabled || isEditing {
            regionWindow.orderFront(nil)
        } else {
            regionWindow.orderOut(nil)
        }
    }

    @objc private func toggleEdit() {
        setEditing(!isEditing)
        if isEditing { NSApp.activate(ignoringOtherApps: true) }
    }

    private func setEditing(_ editing: Bool) {
        isEditing = editing
        UserDefaults.standard.set(editing, forKey: Self.editingKey)
        syncUI()
    }

    @objc private func toggleOutput() {
        if outputWindow.isVisible {
            // Heads up: this also ends any in-progress Meet share of the window.
            outputWindow.orderOut(nil)
        } else {
            outputWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        UserDefaults.standard.set(outputWindow.isVisible, forKey: Self.outputVisibleKey)
        syncUI()
    }

    /// The menu refreshes itself on every open, so a grant made (or revoked) in System
    /// Settings while we were running is reflected without a restart.
    func menuWillOpen(_ menu: NSMenu) {
        hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess, isEnabled { disableMirroring() }
        syncUI()
    }

    @objc private func requestAccess() {
        defer { syncUI() }

        // CGRequestScreenCaptureAccess returns the status it had *before* the user
        // answers, so a false result here does not mean "denied" - it usually means
        // the system dialog is on screen right now. Showing our own alert on top of
        // it is what made this look like being asked for permission twice.
        if !didRequestAccess {
            didRequestAccess = true
            UserDefaults.standard.set(true, forKey: Self.didRequestKey)
            _ = CGRequestScreenCaptureAccess()
            hasAccess = CGPreflightScreenCaptureAccess()
            return
        }

        // Already answered once, so macOS will never prompt again. Now our alert is
        // the only thing that can point anywhere useful.
        hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess { showPermissionAlert("Screen Recording is currently turned off for this app.") }
    }

    @objc private func toggleEnabled() {
        // Belt and braces: the menu item is already greyed out without access, but the
        // action must never turn mirroring on regardless of how it got invoked.
        guard hasAccess || isEnabled else {
            showPermissionAlert("Screen Recording is currently turned off for this app.")
            return
        }
        isEnabled.toggle()
        syncUI()
        if isEnabled {
            NSApp.activate(ignoringOtherApps: true)
            Task { await start() }
        } else {
            disableMirroring()
        }
    }

    /// Tears the stream down rather than pausing it: SCStream is not restartable after
    /// stopCapture, and start() rebuilds it cheaply. The output window stays open and
    /// goes black, so a live Meet share survives the toggle.
    private func disableMirroring() {
        isEnabled = false
        let old = stream
        stream = nil
        Task {
            try? await old?.stopCapture()
            self.videoLayer.flushAndRemoveImage()
        }
    }

    // MARK: Capture

    private func start() async {
        do {
            let filter = try await makeFilter()
            config.width = 1920
            config.height = 1080
            config.scalesToFit = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 5
            config.capturesAudio = false
            config.showsCursor = true
            config.sourceRect = currentSourceRect()

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
        } catch {
            // Capture refused after the toggle already flipped on. Roll the state back
            // so the menu never claims to be mirroring when nothing is being captured.
            hasAccess = CGPreflightScreenCaptureAccess()
            disableMirroring()
            syncUI()
            showPermissionAlert(error.localizedDescription)
        }
    }

    private func makeFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let wanted = regionWindow.screen?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let target = content.displays.first { $0.displayID == wanted }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() }
        guard let target else { throw CaptureError.noDisplay }
        display = target

        // Excluding both of our own windows is what stops the mirror from recursing
        // into itself when the output window overlaps the region.
        let mine = Set([CGWindowID(regionWindow.windowNumber), CGWindowID(outputWindow.windowNumber)])
        let excluded = content.windows.filter { mine.contains($0.windowID) }
        return SCContentFilter(display: target, excludingWindows: excluded)
    }

    private func currentSourceRect() -> CGRect {
        guard let display, let primary = NSScreen.screens.first else { return .zero }
        return Geometry.sourceRect(appKitRect: regionWindow.frame,
                                   primaryHeight: primary.frame.height,
                                   displayOrigin: display.frame.origin)
    }

    private func refreshSourceRect() {
        guard let stream else { return }
        config.sourceRect = currentSourceRect()
        Task { try? await stream.updateConfiguration(config) }
    }

    private func showPermissionAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Virtual Display needs Screen Recording access"
        alert.informativeText = """
            \(reason)

            Turn on "Virtual Display" under Privacy & Security > \
            Screen & System Audio Recording. macOS will offer to relaunch the app \
            once you do.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        // Stays in the tray either way: quitting a menu bar app out from under the
        // user over a permission they may be about to grant is worse than waiting.
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No shareable display found." }
    }

    // MARK: Region tracking

    func windowDidMove(_ notification: Notification) {
        guard notification.object as AnyObject? === regionWindow else { return }
        refreshSourceRect()
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as AnyObject? === regionWindow else { return }
        refreshSourceRect()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as AnyObject? === regionWindow, let stream else { return }
        Task {
            guard let filter = try? await makeFilter() else { return }
            try? await stream.updateContentFilter(filter)
            self.refreshSourceRect()
        }
    }

    // MARK: Frames

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Idle frames carry no new pixels; enqueuing them flashes the mirror black.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        nonisolated(unsafe) let buffer = sampleBuffer
        nonisolated(unsafe) let layer = videoLayer
        DispatchQueue.main.async {
            // ponytail: deprecated on macOS 15+, still works. Move to
            // layer.sampleBufferRenderer.enqueue when the deployment target rises.
            if layer.status == .failed { layer.flush() }
            layer.enqueue(buffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            // Access revoked (or the display went away) mid-session: drop back to the
            // disabled state rather than leaving a dead stream marked as mirroring.
            self.hasAccess = CGPreflightScreenCaptureAccess()
            self.disableMirroring()
            self.syncUI()
            self.showPermissionAlert(error.localizedDescription)
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    Geometry.selftest()
    exit(0)
}

// Prints the on-screen window list the way a conferencing app's window picker builds
// one, so "it is not in the list" can be answered with data instead of guesswork.
if CommandLine.arguments.contains("--list-windows") {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    var listed = 0
    for w in info {
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        guard layer == 0 else { continue }   // pickers only offer normal-level windows
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let title = w[kCGWindowName as String] as? String ?? "<no title readable>"
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        print("\(owner) | \(title) | \(Int(width))x\(Int(height))")
        listed += 1
    }
    print("\n\(listed) normal-level windows on screen.")
    print("Window titles read as <no title readable> unless this terminal has Screen Recording access.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()   // NSApplication.delegate is weak: hold it here
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // tray-only: no Dock icon, no app menu
    app.run()
    _ = delegate
}
