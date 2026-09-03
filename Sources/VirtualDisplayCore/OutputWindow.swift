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
            // ponytail: deprecated on macOS 15+, still works. Move to
            // layer.sampleBufferRenderer.enqueue when the deployment target rises.
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
        // Small by default: it only has to exist for the meeting to have something to
        // share, and it is still resizable if you want to watch it.
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
        contentAspectRatio = NSSize(width: 16, height: 9)
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
}
