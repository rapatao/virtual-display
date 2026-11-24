import AppKit
import AVFoundation
import CoreMedia

/// Receives frames on the capture queue and hands them to the display layer on main.
///
/// Split out from the window so `CaptureController` can deliver frames without touching
/// AppKit, and so the unchecked-Sendable escape hatch is confined to one small type.
public final class VideoSink: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        nonisolated(unsafe) let layer = layer
        DispatchQueue.main.async {
            // Deprecated on macOS 15+; layer.sampleBufferRenderer needs that as the target.
            if layer.status == .failed { layer.flush() }
            layer.enqueue(buffer)
        }
    }

    /// Drops the last frame so the window goes black rather than freezing on it.
    public func blank() {
        nonisolated(unsafe) let layer = layer
        DispatchQueue.main.async { layer.flushAndRemoveImage() }
    }
}

/// The window a meeting actually shares. Its title is what appears in the picker.
@MainActor
public final class OutputWindow: NSWindow {
    public let sink: VideoSink
    /// Whatever plugins drew on top. It lives in this window because this window is what
    /// the meeting shares: no compositing into the capture pipeline is needed.
    public let overlay: OverlayView
    public let drawing: DrawingView?

    /// Set when the window fills a virtual display instead of sitting on the desktop.
    private let displayScreen: NSScreen?

    /// Above the menu bar and Dock, which separate Spaces put on every display.
    static let displayLevel = NSWindow.Level.screenSaver

    /// Parking is meaningless on a display of its own, and falling back to a window from
    /// that mode should not move it off screen either.
    private var parks: Bool
    private let parksByDefault: Bool

    private(set) var pendingRepark: DispatchWorkItem?

    init(sink: VideoSink = VideoSink(), overlay: OverlayView? = nil,
         drawing: DrawingView? = nil, displayScreen: NSScreen? = nil) {
        let overlay = overlay ?? OverlayView()
        self.sink = sink
        self.overlay = overlay
        self.drawing = drawing
        self.displayScreen = displayScreen
        parksByDefault = Preferences.parksOutputWindow && !Preferences.sharesAsDisplay
        parks = parksByDefault
        // Placeholder size: canvasChanged sets the real one once the canvas is known.
        //
        // No .miniaturizable: a minimised window reports onscreen=false and drops
        // straight out of every share picker, which is measurably the same as not having
        // it at all. No .closable: mirroring owns its lifetime.
        //
        // .titled stays even though no title bar is drawn: a share picker lists this
        // window by its title, and an untitled window is one some pickers drop entirely.
        // .fullSizeContentView plus a transparent, hidden title bar is what gets the video
        // into those top 28 points, so what the meeting sees is picture edge to edge with
        // no chrome, like a real display.
        super.init(contentRect: displayScreen?.frame ?? NSRect(x: 100, y: 100, width: 320, height: 180),
                   styleMask: displayScreen == nil ? [.titled, .resizable, .fullSizeContentView]
                                                   : [.borderless],
                   backing: .buffered,
                   defer: false)
        title = "Virtual Display"
        backgroundColor = .black
        isReleasedWhenClosed = false
        if displayScreen == nil {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
            // The title bar was the drag handle; without it the picture itself has to be one.
            isMovableByWindowBackground = true
            // The canvas's shape, so the picture fills the window at any size.
            contentAspectRatio = NSSize(width: OutputCanvas.size.width, height: OutputCanvas.size.height)
        } else {
            level = Self.displayLevel
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            hasShadow = false
            ignoresMouseEvents = true
        }

        sink.layer.videoGravity = .resizeAspect
        sink.layer.backgroundColor = NSColor.black.cgColor

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let video = NSView(frame: content.bounds)
        video.layer = sink.layer   // assign before wantsLayer: makes the view layer-HOSTING
        video.wantsLayer = true
        video.autoresizingMask = [.width, .height]
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        // Overlay above the video, and it never hit-tests, so the window still behaves.
        content.addSubview(video)
        content.addSubview(overlay)
        if let drawing {
            drawing.frame = content.bounds
            drawing.autoresizingMask = [.width, .height]
            content.addSubview(drawing)
        }
        contentView = content

        if displayScreen == nil {
            setFrameUsingName("OutputWindow")
            setFrameAutosaveName("OutputWindow")
        }
    }

    /// Puts the window on screen without making it key or activating the app. A window on
    /// its own display has to be ordered in regardless: a plain `orderFront` of a window
    /// created while another app is active can leave it off screen, and a display with
    /// nothing on screen is not offered by a share picker.
    public func show() {
        if displayScreen == nil { orderFront(nil) } else { orderFrontRegardless() }
    }

    /// Brings a window fully onto its screen, even one that opened parked, and orders it
    /// front without making it key or activating the app. It keeps its 1:1 size and sits
    /// above the region frame and the drawing toolbar until `Preferences.revealSeconds`
    /// have passed, when it returns to the normal level and a window that opened parked
    /// parks again. Revealing again restarts that wait. A window on a display only comes
    /// to the front.
    public func reveal() {
        if displayScreen == nil {
            let target = screen ?? NSScreen.main
            level = Self.revealedLevel
            parks = false
            canvasChanged()
            if let visible = target?.visibleFrame {
                setFrameOrigin(Geometry.clamp(frame, into: visible).origin)
            }
            scheduleRepark()
            startWatchingPicker()
        }
        orderFrontRegardless()
    }

    /// One above the drawing toolbar (floating + 1), which is one above the region frame
    /// (floating), so a picker finds this window first under the pointer.
    nonisolated static let revealedLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

    static let reparkRetry: TimeInterval = 1

    /// A press in progress could be a click on a picker's Share button or a drag, and
    /// parking under it would interrupt either.
    static func shouldPostponeRepark(pressedButtons: Int) -> Bool { pressedButtons != 0 }

    func scheduleRepark(after delay: TimeInterval? = nil) {
        pendingRepark?.cancel()
        pendingRepark = nil
        guard displayScreen == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.shouldPostponeRepark(pressedButtons: Int(NSEvent.pressedMouseButtons)) {
                    self.scheduleRepark(after: Self.reparkRetry)
                } else {
                    self.repark()
                }
            }
        }
        pendingRepark = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Preferences.revealSeconds),
                                      execute: item)
    }

    static func shouldRevealOnStart(parked: Bool, onDisplay: Bool, enabled: Bool) -> Bool {
        parked && !onDisplay && enabled
    }

    /// Reveals a window that opened parked, when the setting asks for it.
    func revealOnStart() {
        if Self.shouldRevealOnStart(parked: parksByDefault, onDisplay: displayScreen != nil,
                                    enabled: Preferences.revealsOnStart) {
            reveal()
        }
    }

    private var pickerWatch = PickerWatch()
    private var pickerTimer: Timer?
    private var revealedAt = Date()

    private func startWatchingPicker() {
        stopWatchingPicker()
        guard parksByDefault, Preferences.parksWhenPickerCloses else { return }
        pickerWatch = PickerWatch()
        revealedAt = Date()
        let timer = Timer(timeInterval: PickerWatch.pollInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.pollPicker()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pickerTimer = timer
    }

    private func stopWatchingPicker() {
        pickerTimer?.invalidate()
        pickerTimer = nil
    }

    private func pollPicker() {
        let park = pickerWatch.poll(bannerShown: PickerBanner.currentlyShown(),
                                    age: Date().timeIntervalSince(revealedAt))
        if park, !Self.shouldPostponeRepark(pressedButtons: Int(NSEvent.pressedMouseButtons)) {
            repark()
        }
    }

    /// Whether a picker banner has been seen since the last reveal.
    var pickerWasSeen: Bool { pickerWatch.seen }

    func repark() {
        pendingRepark?.cancel()
        pendingRepark = nil
        stopWatchingPicker()
        level = .normal
        parks = parksByDefault
        if parksByDefault { canvasChanged() }
    }

    public override func close() {
        pendingRepark?.cancel()
        pendingRepark = nil
        stopWatchingPicker()
        if displayScreen == nil { level = .normal }
        super.close()
    }

    /// Fills the display again after its size or position changed. No-op for a window.
    public func refitToDisplay() {
        guard let displayScreen else { return }
        let current = displayScreen.displayID.flatMap(VirtualScreen.screen(for:)) ?? displayScreen
        if frame != current.frame { setFrame(current.frame, display: true) }
    }

    /// How much of a parked window stays on the display, in points: enough to be listed by
    /// a share picker and to grab and drag back.
    static let parkedVisible: CGFloat = 40

    /// Adopts the current canvas at 1:1: one canvas pixel per backing pixel. A meeting
    /// captures the window's pixels, so any smaller window is shared upscaled and blurred.
    /// Clamped to the visible screen, keeping the canvas's shape, when that is too big,
    /// unless parked: a parked window is off screen anyway and stays 1:1 at any size.
    public func canvasChanged() {
        if displayScreen != nil {
            refitToDisplay()
            return
        }
        let canvas = OutputCanvas.size
        contentAspectRatio = NSSize(width: canvas.width, height: canvas.height)
        let screen = self.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        var size = NSSize(width: canvas.width / scale, height: canvas.height / scale)
        if !parks, let visible = screen?.visibleFrame {
            let fit = min(1, visible.width / size.width, visible.height / size.height)
            size = NSSize(width: (size.width * fit).rounded(.down),
                          height: (size.height * fit).rounded(.down))
        }
        let top = frame.maxY
        setContentSize(size)
        if parks, let visible = screen?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: visible.maxX - Self.parkedVisible,
                                         y: visible.minY + Self.parkedVisible))
        } else {
            setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
        }
    }

    /// AppKit pulls a titled window back onto the screen when it is shown; a parked one
    /// has to stay where it was put.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        parks || displayScreen != nil ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
