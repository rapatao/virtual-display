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
    public let sink = VideoSink()
    /// Whatever plugins drew on top. It lives in this window because this window is what
    /// the meeting shares: no compositing into the capture pipeline is needed.
    public let overlay = OverlayView()

    public init() {
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
        super.init(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
                   styleMask: [.titled, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        title = "Virtual Display"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // The title bar was the drag handle; without it the picture itself has to be one.
        isMovableByWindowBackground = true
        // Behind the video: the rounded corners a titled window keeps are transparent
        // otherwise, and a meeting renders that as whatever was underneath.
        backgroundColor = .black
        // The canvas's shape, so the picture fills the window at any size.
        contentAspectRatio = NSSize(width: OutputCanvas.size.width, height: OutputCanvas.size.height)
        isReleasedWhenClosed = false

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
        contentView = content

        setFrameUsingName("OutputWindow")
        setFrameAutosaveName("OutputWindow")
    }

    /// How much of a parked window stays on the display, in points: enough to be listed by
    /// a share picker and to grab and drag back.
    static let parkedVisible: CGFloat = 40

    /// Adopts the current canvas at 1:1: one canvas pixel per backing pixel. A meeting
    /// captures the window's pixels, so any smaller window is shared upscaled and blurred.
    /// Clamped to the visible screen, keeping the canvas's shape, when that is too big,
    /// unless parked: a parked window is off screen anyway and stays 1:1 at any size.
    public func canvasChanged() {
        let canvas = OutputCanvas.size
        contentAspectRatio = NSSize(width: canvas.width, height: canvas.height)
        let screen = self.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        var size = NSSize(width: canvas.width / scale, height: canvas.height / scale)
        let parks = Preferences.parksOutputWindow
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
        Preferences.parksOutputWindow ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
