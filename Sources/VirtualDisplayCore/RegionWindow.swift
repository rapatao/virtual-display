import AppKit

/// Draws the region outline. Red while editing, green while locked.
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

/// The floating frame that marks which part of the screen is mirrored.
///
/// Owns everything about the region rectangle: placement, presets, snapping, and
/// clamping. It is its own delegate, so callers get plain closures instead of having to
/// disambiguate window notifications.
@MainActor
public final class RegionWindow: NSWindow, NSWindowDelegate {

    private let border = BorderView()

    /// The region moved or resized: the capture rectangle needs recomputing.
    public var onFrameChanged: (() -> Void)?
    /// The region landed on a different display: the content filter needs rebuilding.
    public var onScreenChanged: (() -> Void)?

    public var isEditing: Bool = true {
        didSet {
            border.isEditing = isEditing
            ignoresMouseEvents = !isEditing
        }
    }

    public init() {
        super.init(contentRect: NSRect(x: 200, y: 200, width: 960, height: 540),
                   styleMask: [.titled, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 160, height: 90)
        contentView = border

        // Restore before registering autosave, otherwise AppKit writes the default frame
        // out before the saved one has been read back.
        setFrameUsingName("RegionWindow")
        setFrameAutosaveName("RegionWindow")
        // Delegate LAST. setFrameUsingName posts NSWindowDidMove synchronously, and a
        // delegate callback reaching back into a half-built window is how this used to
        // recurse until the stack died.
        delegate = self
    }

    // MARK: Placement

    private var visibleArea: CGRect? { (screen ?? NSScreen.main)?.visibleFrame }

    /// Every programmatic move goes through here, so the region can never be parked
    /// off-screen or made bigger than the display it sits on.
    public func place(_ proposed: NSRect) {
        guard let visibleArea else { return }
        // setFrame posts didMove/didResize, so onFrameChanged fires from the delegate.
        setFrame(Geometry.clamp(proposed, into: visibleArea), display: true)
    }

    public func apply(size preset: RegionSize) {
        guard let visibleArea else { return }
        place(Geometry.resizedFromTop(frame, to: preset.resolved(in: visibleArea)))
    }

    public func apply(spot: RegionSpot) {
        guard let visibleArea else { return }
        var f = frame
        f.origin = Geometry.origin(for: spot, size: f.size, in: visibleArea)
        place(f)
    }

    /// Sizes the region to the frontmost ordinary window under its centre, which is the
    /// fiddly part of setup if done by hand. False when there is nothing to snap to.
    @discardableResult
    public func snapToWindowBelow() -> Bool {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Front to back, so the first hit is the window you can actually see.
        guard let hit = ScreenWindows.list().first(where: { $0.frame.contains(centre) }) else {
            return false
        }
        place(hit.frame)
        return true
    }

    // MARK: NSWindowDelegate

    public func windowDidMove(_ notification: Notification) { onFrameChanged?() }
    public func windowDidResize(_ notification: Notification) { onFrameChanged?() }
    public func windowDidChangeScreen(_ notification: Notification) { onScreenChanged?() }
}

/// An ordinary window belonging to some other app.
public struct ScreenWindow: Sendable {
    public let app: String
    public let title: String
    public let pid: Int32
    /// AppKit coordinates, so it can go straight back into `RegionWindow.place`.
    public let frame: CGRect
}

/// The on-screen window list, front to back, minus our own windows. Snapping needs it and
/// so does any plugin that wants to follow a particular app, so it lives in one place.
public enum ScreenWindows {
    public static func list() -> [ScreenWindow] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let mine = ProcessInfo.processInfo.processIdentifier
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        return listed.compactMap { w in
            // Layer 0 is an ordinary window; panels and menu bar items sit above it.
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != mine,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return ScreenWindow(
                app: w[kCGWindowOwnerName as String] as? String ?? "",
                // Window titles need Screen Recording permission; empty without it.
                title: w[kCGWindowName as String] as? String ?? "",
                pid: pid,
                frame: Geometry.appKitRect(fromCG: rect, primaryHeight: primaryHeight))
        }
    }
}
