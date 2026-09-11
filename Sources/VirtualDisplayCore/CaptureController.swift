import AppKit
import CoreMedia
import ScreenCaptureKit

/// The pixel canvas everything is produced at: the live mirror, screenshots and
/// recordings. Set from `config.json` at launch and whenever that file changes.
public enum OutputCanvas {
    /// 1080p, which 960x540 points on a Retina display mirrors into 1:1.
    public static let standard = CGSize(width: 1920, height: 1080)
    public static var size: CGSize = standard
    /// The shape the region is held to while the aspect lock is on.
    public static var aspect: CGSize { size }
}

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

        public init(regionFrame: @escaping () -> CGRect,
                    regionScreen: @escaping () -> NSScreen?) {
            self.regionFrame = regionFrame
            self.regionScreen = regionScreen
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

    /// Starting is not instant: building the filter and `startCapture` are both awaited,
    /// and a toggle landing in that window used to find nothing to act on.
    private var isStarting = false
    /// What was last asked for, so a `stop` that arrives mid-start is still honoured.
    private var wantsRunning = false
    private var blanksOnStop = true

    /// Counts the half-built stream too: `render()` decides whether to start from this,
    /// and a second start would build a stream nothing holds a reference to.
    public var isRunning: Bool { stream != nil || isStarting }

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
        guard !isRunning else { return }
        isStarting = true
        wantsRunning = true
        defer { isStarting = false }

        let filter = try await makeFilter()
        config.width = Int(OutputCanvas.size.width)
        config.height = Int(OutputCanvas.size.height)
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

        // Mirroring was turned off while this was starting. That `stop` found no stream to
        // stop, so it is honoured here: otherwise the capture runs on, with the recording
        // indicator lit, while the menu says it is off.
        guard wantsRunning else {
            try? await s.stopCapture()
            if blanksOnStop { sink.blank() }
            return
        }
        stream = s
    }

    /// `blanking: false` leaves the last frame in the output window instead of clearing
    /// it, which is what a pause set to freeze shows.
    public func stop(blanking: Bool = true) {
        wantsRunning = false
        blanksOnStop = blanking
        guard let old = stream else { return }
        stream = nil
        Task {
            try? await old.stopCapture()
            if blanking { self.sink.blank() }
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

    /// The output canvas changed. A stopped stream reads the new size on its next `start`.
    public func canvasChanged() {
        guard stream != nil else { return }
        config.width = Int(OutputCanvas.size.width)
        config.height = Int(OutputCanvas.size.height)
        pushConfiguration()
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

        // Every window this app owns is excluded: the region frame and the output window,
        // which would recurse the mirror into itself, and the alerts, settings window and
        // shortcut HUD that can sit over the region.
        let mine = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        return SCContentFilter(display: target, excludingApplications: mine, exceptingWindows: [])
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
