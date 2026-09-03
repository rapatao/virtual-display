import AppKit
import CoreMedia
import ScreenCaptureKit

/// Owns the ScreenCaptureKit stream and nothing else.
///
/// It never reaches into windows: `Source` supplies the rectangle to capture and the
/// windows to exclude, so swapping in a different way of choosing them (an
/// `SCContentSharingPicker`, a second region) touches only the caller.
@MainActor
public final class CaptureController: NSObject, SCStreamDelegate, SCStreamOutput {

    /// Where the capture rectangle and exclusions come from.
    public struct Source {
        public var regionFrame: () -> CGRect
        public var regionScreen: () -> NSScreen?
        /// Our own windows. Excluding them is what stops the mirror from recursing into
        /// itself when the output window overlaps the region.
        public var excludedWindowNumbers: () -> [Int]

        public init(regionFrame: @escaping () -> CGRect,
                    regionScreen: @escaping () -> NSScreen?,
                    excludedWindowNumbers: @escaping () -> [Int]) {
            self.regionFrame = regionFrame
            self.regionScreen = regionScreen
            self.excludedWindowNumbers = excludedWindowNumbers
        }
    }

    public enum CaptureError: LocalizedError {
        case noDisplay
        public var errorDescription: String? { "No shareable display found." }
    }

    /// Capture stopped on its own: access revoked, or the display went away.
    public var onFailure: ((Error) -> Void)?

    private let source: Source
    /// nonisolated so frames can be handed over straight from the capture queue.
    nonisolated private let sink: VideoSink
    private let sampleQueue = DispatchQueue(label: "com.rapatao.virtual-display.capture")

    private var stream: SCStream?
    private var config = SCStreamConfiguration()
    private var display: SCDisplay?

    public var isRunning: Bool { stream != nil }

    public var showsCursor: Bool = true {
        didSet {
            config.showsCursor = showsCursor
            pushConfiguration()
        }
    }

    public init(source: Source, sink: VideoSink) {
        self.source = source
        self.sink = sink
        super.init()
    }

    // MARK: Lifetime

    /// SCStream is not restartable after stopCapture, so stopping means discarding and
    /// rebuilding. `start` is cheap enough that this is not worth working around.
    public func start() async throws {
        guard stream == nil else { return }

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
    }

    public func stop() {
        guard let old = stream else { return }
        stream = nil
        Task {
            try? await old.stopCapture()
            self.sink.blank()   // leaves the window black rather than frozen
        }
    }

    // MARK: Region tracking

    /// The region moved or resized.
    public func regionChanged() {
        config.sourceRect = currentSourceRect()
        pushConfiguration()
    }

    /// The region landed on a different display, so the filter itself is stale.
    public func screenChanged() {
        guard let stream else { return }
        Task {
            guard let filter = try? await makeFilter() else { return }
            try? await stream.updateContentFilter(filter)
            self.regionChanged()
        }
    }

    private func pushConfiguration() {
        guard let stream else { return }
        Task { try? await stream.updateConfiguration(config) }
    }

    // MARK: Building the stream

    private func makeFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        let wanted = source.regionScreen()?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let target = content.displays.first { $0.displayID == wanted }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() }
        guard let target else { throw CaptureError.noDisplay }
        display = target

        let mine = Set(source.excludedWindowNumbers().map { CGWindowID($0) })
        return SCContentFilter(display: target,
                               excludingWindows: content.windows.filter { mine.contains($0.windowID) })
    }

    private func currentSourceRect() -> CGRect {
        guard let display, let primary = NSScreen.screens.first else { return .zero }
        return Geometry.sourceRect(appKitRect: source.regionFrame(),
                                   primaryHeight: primary.frame.height,
                                   displayOrigin: display.frame.origin)
    }

    // MARK: SCStream callbacks

    nonisolated public func stream(_ stream: SCStream,
                                   didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                   of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Idle frames carry no new pixels; enqueuing them flashes the mirror black.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        sink.enqueue(sampleBuffer)
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.onFailure?(error)
        }
    }
}
