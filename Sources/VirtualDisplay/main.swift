import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

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

    /// Inverse of `sourceRect`: CGWindowList reports window bounds in display space
    /// (y-down from the primary screen's top), and NSWindow.setFrame wants AppKit space.
    static func appKitRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX,
               y: primaryHeight - r.maxY,
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

        // A window 100pt below the top of a 1440pt screen sits 1140pt up in AppKit space.
        let win = appKitRect(fromCG: CGRect(x: 300, y: 100, width: 800, height: 200),
                             primaryHeight: 1440)
        precondition(win == CGRect(x: 300, y: 1140, width: 800, height: 200), "cg->appkit wrong: \(win)")

        // The two conversions must be exact inverses, or snapping drifts every use.
        let start = CGRect(x: 120, y: 340, width: 640, height: 400)
        let round = appKitRect(fromCG: sourceRect(appKitRect: start, primaryHeight: 1440,
                                                  displayOrigin: .zero),
                               primaryHeight: 1440)
        precondition(round == start, "round trip wrong: \(round)")

        print("selftest OK")
    }
}

// MARK: - Diagnostics

/// Why a window is or is not offered by a conferencing app's share picker. Works both
/// in-process (the Copy Diagnostics menu item) and from a second process launched with
/// --list-windows, because it looks the app up through NSWorkspace either way.
enum Diagnostics {
    static func report() -> String {
        var out: [String] = ["Virtual Display diagnostics"]
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        out.append("build: \(version ?? "unknown")")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("screen recording (this process): \(CGPreflightScreenCaptureAccess())")

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.rapatao.virtual-display"
        }
        out.append("")
        if apps.isEmpty {
            out.append("Virtual Display is NOT running.")
        }
        for a in apps {
            let policy: String
            switch a.activationPolicy {
            case .regular: policy = "regular (Dock icon)"
            case .accessory: policy = "accessory (tray only)"
            case .prohibited: policy = "prohibited"
            @unknown default: policy = "unknown"
            }
            out.append("running: pid \(a.processIdentifier), policy: \(policy)")
            out.append("bundle:  \(a.bundleURL?.path ?? "?")")
        }

        let pids = Set(apps.map { $0.processIdentifier })
        func dump(_ label: String, _ options: CGWindowListOption) {
            let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            let mine = all.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
            out.append("")
            out.append("\(label): \(mine.count)")
            for w in mine {
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let num = { (k: String) in Int((b[k] as? Double) ?? 0) }
                // Layer 0 is the output window, the only one a picker can ever offer.
                // The region frame is .floating, so it sits at layer 3.
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                let role = layer == 0 ? "OUTPUT WINDOW (the shareable one)"
                                      : "region frame (never shareable)"
                out.append("  \(role)")
                out.append("  layer=\(w[kCGWindowLayer as String] as? Int ?? -1)"
                    + " onscreen=\(w[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                    + " alpha=\(w[kCGWindowAlpha as String] as? Double ?? -1)"
                    + " at \(num("X")),\(num("Y"))"
                    + " size \(num("Width"))x\(num("Height"))"
                    + " title=\(w[kCGWindowName as String] as? String ?? "<not readable>")")
            }
        }
        // A picker only offers the first set. The second tells off-screen apart from absent.
        dump("on-screen normal windows (what a picker lists)", [.optionOnScreenOnly, .excludeDesktopElements])
        dump("all windows incl. off-screen", [.optionAll, .excludeDesktopElements])

        out.append("")
        out.append("screens:")
        for s in NSScreen.screens {
            out.append("  \(s.frame) visible \(s.visibleFrame)")
        }
        return out.joined(separator: "\n")
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

// MARK: - Hot key callback

/// Must be a free function: Carbon takes a C function pointer, which cannot capture self.
private func hotKeyHandler(_ next: EventHandlerCallRef?,
                           _ event: EventRef?,
                           _ context: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let raw = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { App.shared?.handleHotKey(raw) }
    }
    return noErr
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
    private static let editingKey = "editRegion"
    private var isEditing = UserDefaults.standard.object(forKey: App.editingKey) as? Bool ?? true
    // Off at launch: the app comes up as a tray icon only, no windows, no capture.
    private var isEnabled = false
    /// Session-only, never persisted: a pause is something you undo within a meeting.
    /// Suppresses capture while leaving the output window on screen, so the meeting
    /// keeps the window selected and the share survives.
    private var isPaused = false
    private static let cursorKey = "showsCursor"
    private var showsCursor = UserDefaults.standard.object(forKey: App.cursorKey) as? Bool ?? true
    /// Re-read on every menu open, so revoking access mid-session greys the toggle out.
    private var hasAccess = CGPreflightScreenCaptureAccess()
    /// macOS shows its Screen Recording dialog exactly once per app, ever. There is no
    /// API to ask whether that has happened, so remember it ourselves.
    private static let didRequestKey = "didRequestScreenRecordingAccess"
    private var didRequestAccess = UserDefaults.standard.bool(forKey: App.didRequestKey)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let enabledItem = NSMenuItem(title: "Mirroring", action: #selector(toggleEnabled), keyEquivalent: "")
    private let editItem = NSMenuItem(title: "Edit Region", action: #selector(toggleEdit), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Allow Screen Recording...", action: #selector(requestAccess), keyEquivalent: "")
    private let presetItem = NSMenuItem(title: "Region Presets", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let cursorItem = NSMenuItem(title: "Show Cursor in Share", action: #selector(toggleCursor), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")

    /// Set once so the C hot key callback, which cannot capture context, can find us.
    static weak var shared: App?
    private var hotKeys: [EventHotKeyRef?] = []

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
        // Small by default: it only has to exist for the meeting to have something to
        // share, and it is still resizable if you want to watch it. No .miniaturizable:
        // a minimised window reports onscreen=false and drops straight out of every
        // share picker, which is measurably the same as not having it at all.
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
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
        App.shared = self
        installMainMenu()
        // Permission is checked on first enable so launching never puts a dialog up.
        installStatusItem()
        registerHotKeys()
    }

    /// Carbon hot keys, not an NSEvent global monitor: RegisterEventHotKey works without
    /// Accessibility permission, which is the whole reason to prefer the older API here.
    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)

        // Control-Option-Command is deep enough to avoid colliding with anything common.
        let mods = UInt32(controlKey | optionKey | cmdKey)
        for (id, key) in [(HotKey.mirroring, kVK_ANSI_M), (HotKey.pause, kVK_ANSI_P)] {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x56_44_49_53), id: id.rawValue)
            RegisterEventHotKey(UInt32(key), mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    enum HotKey: UInt32 {
        case mirroring = 1
        case pause = 2
    }

    func handleHotKey(_ raw: UInt32) {
        switch HotKey(rawValue: raw) {
        case .mirroring: toggleEnabled()
        case .pause: togglePause()
        case nil: break
        }
    }

    private func installStatusItem() {
        let menu = NSMenu()

        enabledItem.keyEquivalent = "m"
        pauseItem.keyEquivalent = "p"
        for item in [enabledItem, pauseItem] {
            item.keyEquivalentModifierMask = [.control, .option, .command]
        }
        for item in [accessItem, enabledItem, pauseItem, editItem] {
            item.target = self
            menu.addItem(item)
        }
        presetItem.submenu = buildPresetMenu()
        menu.addItem(presetItem)
        menu.addItem(.separator())
        for item in [cursorItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let diag = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
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

        menu.addItem(.separator())
        let snap = NSMenuItem(title: "Snap to Window Below", action: #selector(snapToWindowBelow), keyEquivalent: "")
        snap.target = self
        menu.addItem(snap)
        return menu
    }

    /// Sizes the region to the frontmost ordinary window under its centre, which is the
    /// fiddly part of setup done by hand otherwise.
    @objc private func snapToWindowBelow() {
        guard let primary = NSScreen.screens.first else { return }
        let centre = CGPoint(x: regionWindow.frame.midX,
                             y: primary.frame.height - regionWindow.frame.midY)  // CG space

        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        // The list is front to back, so the first hit is the window you can actually see.
        for w in listed {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.contains(centre)
            else { continue }
            setRegionFrame(Geometry.appKitRect(fromCG: rect, primaryHeight: primary.frame.height))
            return
        }
        NSSound.beep()   // nothing under the region to snap to
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
        else if isEnabled && isPaused { symbol = "pause.rectangle" }
        else if isEnabled { symbol = "rectangle.on.rectangle" }
        else { symbol = "rectangle.on.rectangle.slash" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Virtual Display")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Virtual Display")

        // No Screen Recording grant means mirroring is not merely refused on click,
        // it is not offerable: the toggle greys out and a fix-it row takes its place.
        accessItem.isHidden = hasAccess
        enabledItem.isEnabled = hasAccess
        enabledItem.state = isEnabled ? .on : .off
        // Pause is meaningless with nothing running, and must not look available then.
        pauseItem.isEnabled = isEnabled
        pauseItem.state = isPaused ? .on : .off
        cursorItem.state = showsCursor ? .on : .off
        cursorItem.isEnabled = true
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.isEnabled = true
        // Region controls stay live with mirroring off: placing the region is a setup
        // task you do before joining a call, not something gated on capture running.
        editItem.state = isEditing ? .on : .off
        editItem.isEnabled = true
        presetItem.isEnabled = true
        // The output window exists solely to be shared, so it follows mirroring rather
        // than being managed by hand. orderFront, never makeKeyAndOrderFront: it must
        // not steal focus from whatever you are about to drag into the region.
        if isEnabled {
            outputWindow.orderFront(nil)
        } else {
            outputWindow.orderOut(nil)
        }
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

    @objc private func copyDiagnostics() {
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
        if isEnabled {
            isPaused = false   // a fresh start is never a paused one
            NSApp.activate(ignoringOtherApps: true)
        }
        syncUI()
        applyStreamState()
    }

    /// Suppresses capture without touching the output window, so the meeting keeps the
    /// window selected and the share survives. Turning mirroring off instead closes the
    /// window and ends the share, which is not what you want mid-sentence.
    @objc private func togglePause() {
        guard isEnabled else { return }
        isPaused.toggle()
        syncUI()
        applyStreamState()
    }

    private func disableMirroring() {
        isEnabled = false
        applyStreamState()
    }

    /// The single owner of the stream's lifetime. Capture runs exactly when mirroring is
    /// on and not paused; every other path just sets state and calls this. SCStream is
    /// not restartable after stopCapture, so stopping means discarding and rebuilding.
    private func applyStreamState() {
        let shouldRun = isEnabled && !isPaused
        if shouldRun {
            guard stream == nil else { return }
            Task { await start() }
        } else {
            guard let old = stream else { return }
            stream = nil
            Task {
                try? await old.stopCapture()
                self.videoLayer.flushAndRemoveImage()   // leaves the window black
            }
        }
    }

    @objc private func toggleCursor() {
        showsCursor.toggle()
        UserDefaults.standard.set(showsCursor, forKey: Self.cursorKey)
        config.showsCursor = showsCursor
        if let stream { Task { try? await stream.updateConfiguration(config) } }
        syncUI()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            // Registration only works for a real app bundle in a stable location, so
            // this fails for a build run straight out of .build.
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        syncUI()
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
            config.showsCursor = showsCursor
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

// Answers "why is it not in the share list" with data instead of guesswork.
// Same report as the Copy Diagnostics menu item.
if CommandLine.arguments.contains("--doctor") || CommandLine.arguments.contains("--list-windows") {
    print(Diagnostics.report())
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
