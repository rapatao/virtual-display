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

    public init() {
        // Small by default: it only has to exist for the meeting to have something to
        // share, and it is still resizable if you want to watch it.
        //
        // No .miniaturizable: a minimised window reports onscreen=false and drops
        // straight out of every share picker, which is measurably the same as not having
        // it at all. No .closable: mirroring owns its lifetime.
        super.init(contentRect: NSRect(x: 100, y: 100, width: 320, height: 180),
                   styleMask: [.titled, .resizable],
                   backing: .buffered,
                   defer: false)
        title = "Virtual Display"
        contentAspectRatio = NSSize(width: 16, height: 9)
        isReleasedWhenClosed = false

        sink.layer.videoGravity = .resizeAspect
        sink.layer.backgroundColor = NSColor.black.cgColor
        let host = NSView()
        host.layer = sink.layer   // assign before wantsLayer: makes the view layer-HOSTING
        host.wantsLayer = true
        contentView = host

        setFrameUsingName("OutputWindow")
        setFrameAutosaveName("OutputWindow")
    }
}
