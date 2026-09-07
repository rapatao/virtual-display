import AVFoundation
import AppKit
import ScreenCaptureKit

/// Where screenshots and recordings land, and what they are called.
///
/// The system folders rather than a folder of our own invention, so the files turn up
/// where anyone would look for them.
public enum CaptureFiles {
    /// Set from the config file at launch; empty means the system folders.
    public static var screenshotFolder: String?
    public static var recordingFolder: String?

    public static func screenshot(at date: Date = Date()) throws -> URL {
        try folder(screenshotFolder, or: .picturesDirectory)
            .appendingPathComponent("Screenshot \(stamp(date)).png")
    }

    public static func recording(at date: Date = Date()) throws -> URL {
        try folder(recordingFolder, or: .moviesDirectory)
            .appendingPathComponent("Recording \(stamp(date)).mov")
    }

    private static func folder(_ chosen: String?,
                               or fallback: FileManager.SearchPathDirectory) throws -> URL {
        guard let chosen, !chosen.isEmpty else { return try directory(fallback) }
        let url = URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "2026-09-03 at 22.15.00", the shape macOS uses for its own screenshots. Colons are
    /// legal in a file name and displayed as slashes in Finder, hence the dots.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    static func directory(_ search: FileManager.SearchPathDirectory) throws -> URL {
        let base = try FileManager.default.url(for: search, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("Virtual Display")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

public enum CaptureFailure: LocalizedError {
    case windowGone
    case noFrames
    case writer(String)
    /// The picture is still being recorded; only the sound is missing.
    case microphone(String)

    public var errorDescription: String? {
        switch self {
        case .windowGone: return "The shared window is not on screen. Turn mirroring on first."
        case .noFrames: return "No frames arrived, so nothing was written."
        case .writer(let why): return why
        case .microphone(let why): return "Recording without audio: \(why)"
        }
    }
}

/// A filter over one window of ours.
///
/// Screenshots and recordings both capture the output window rather than the region, so
/// what they produce is exactly what the meeting sees, overlays included, with no separate
/// compositing path to keep in step with the drawing code.
enum WindowCapture {
    static func filter(windowNumber: Int) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) })
        else { throw CaptureFailure.windowGone }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    /// The same canvas the mirror itself produces, so a still, a recording and the live
    /// share are all the same shape whatever size the window happens to be.
    static func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(OutputCanvas.size.width)
        config.height = Int(OutputCanvas.size.height)
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false      // the pointer is never over the output window's copy
        config.capturesAudio = false
        return config
    }
}

public enum Screenshot {
    /// Writes a PNG of the shared window and returns where it went.
    public static func capture(windowNumber: Int, to url: URL) async throws -> URL {
        try await png(windowNumber: windowNumber).write(to: url)
        return url
    }

    /// The same picture, on the clipboard instead of in a file.
    public static func copyToClipboard(windowNumber: Int) async throws {
        let data = try await png(windowNumber: windowNumber)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
    }

    private static func png(windowNumber: Int) async throws -> Data {
        let filter = try await WindowCapture.filter(windowNumber: windowNumber)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: WindowCapture.configuration())

        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CaptureFailure.writer("could not encode a PNG")
        }
        return png
    }
}

/// Writes frames to a QuickTime file. Not main-actor: frames arrive on the capture queue
/// and are appended there, which is also what serialises access to the writer.
final class SampleWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// Present only when a microphone was started. Every input has to exist before the
    /// first sample is written, so the microphone is opened before the writer is built.
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var started = false

    /// `audioSettings` come from `AVCaptureAudioDataOutput`, which knows the format the
    /// device delivers. Nil records no audio track at all.
    init(url: URL, size: CGSize, audioSettings: [String: Any]? = nil) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        // Real time: the encoder must not hold frames back waiting for a better decision.
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureFailure.writer("the writer refused a video track") }
        writer.add(input)

        guard let audioSettings else {
            audioInput = nil
            return
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(audio) else {
            throw CaptureFailure.writer("the writer refused an audio track")
        }
        writer.add(audio)
        audioInput = audio
    }

    func append(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard writer.status == .writing || !started else { return }

        if !started {
            guard writer.startWriting() else {
                return   // status carries the reason; `finish` reports it
            }
            startedAt = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: startedAt)
            started = true
        }
        // Dropping a frame is right here: blocking would stall the capture queue and with
        // it the live mirror, which matters more than a complete recording.
        guard input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    /// Sound arrives on its own queue, often before the first frame. The session starts
    /// at the first video sample, and anything older than that is dropped: the writer
    /// refuses a sample from before the session began.
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard started, writer.status == .writing, let audioInput,
              audioInput.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startedAt
        else { return }
        audioInput.append(sample)
    }

    private var startedAt: CMTime = .zero

    /// Finalises the file. An unfinalised .mov is not playable, so this must run on every
    /// path out of recording, including quit.
    func finish() async throws {
        lock.lock()
        let hadFrames = started
        if started {
            input.markAsFinished()
            audioInput?.markAsFinished()
        }
        lock.unlock()

        guard hadFrames else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw CaptureFailure.noFrames
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw CaptureFailure.writer(writer.error?.localizedDescription ?? "the recording failed")
        }
    }
}

/// Receives frames on the capture queue and appends them. A separate object from the
/// recorder because the recorder is main-actor and frames never arrive there.
private final class RecorderOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: SampleWriter

    init(writer: SampleWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Idle frames carry no new pixels, exactly as in CaptureController.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        writer.append(sampleBuffer)
    }
}

/// The presenter's voice on a recording.
///
/// Not ScreenCaptureKit's own audio, which is tied to the content filter: ours is this
/// app's own silent output window, so it would record nothing. `SCStreamConfiguration`
/// gained microphone capture in macOS 15, one version above this app's target.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.rapatao.virtual-display.microphone")

    /// Set before `start`, called on the audio queue.
    var onSample: ((CMSampleBuffer) -> Void)?

    /// What the writer's audio track should be configured with, as reported by the
    /// running device.
    var recommendedSettings: [String: Any]? {
        output.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
    }

    func start() async throws {
        guard await Self.authorized() else {
            throw CaptureFailure.microphone("microphone access is off for this app")
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureFailure.microphone("no microphone is connected")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureFailure.microphone("the microphone could not be opened")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)

        // startRunning blocks until the device is live, so it runs off the main thread.
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
    }

    /// macOS asks once and remembers; afterwards this returns the stored answer.
    private static func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}

/// Records the shared window to a file. One stream, one writer, both torn down together.
@MainActor
public final class Recorder: NSObject, SCStreamDelegate {

    public private(set) var url: URL?
    public var isRecording: Bool { stream != nil }
    /// Reported when the stream dies on its own, so the menu cannot keep claiming to record.
    public var onFailure: ((Error) -> Void)?
    /// Why a recording that asked for sound is not getting any. The picture records
    /// either way; a missing microphone does not stop the take.
    public private(set) var microphoneFailure: String?

    private var stream: SCStream?
    private var writer: SampleWriter?
    private var output: RecorderOutput?
    private var microphone: MicrophoneCapture?
    private let queue = DispatchQueue(label: "com.rapatao.virtual-display.recorder")

    public func start(windowNumber: Int, to destination: URL, microphone recordAudio: Bool) async throws {
        guard stream == nil else { return }
        microphoneFailure = nil

        let filter = try await WindowCapture.filter(windowNumber: windowNumber)
        let config = WindowCapture.configuration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // 30fps is plenty for a screen
        config.queueDepth = 6

        // Before the writer: only a running device can describe the track it needs.
        var microphone: MicrophoneCapture?
        if recordAudio {
            do {
                let capture = MicrophoneCapture()
                try await capture.start()
                microphone = capture
            } catch {
                microphoneFailure = error.localizedDescription
            }
        }

        let writer = try SampleWriter(url: destination,
                                      size: CGSize(width: config.width, height: config.height),
                                      audioSettings: microphone?.recommendedSettings)
        microphone?.onSample = { [writer] sample in writer.appendAudio(sample) }
        let output = RecorderOutput(writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            microphone?.stop()   // the device stays open otherwise
            throw error
        }

        self.output = output
        self.writer = writer
        self.microphone = microphone
        self.stream = stream
        self.url = destination
    }

    /// Returns where the file went. Stopping is also the only thing that makes it playable.
    @discardableResult
    public func stop() async throws -> URL? {
        guard let stream, let writer else { return nil }
        self.stream = nil
        self.writer = nil
        self.output = nil
        microphone?.stop()
        microphone = nil

        try? await stream.stopCapture()
        try await writer.finish()
        return url
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream != nil else { return }   // our own stop, already handled
            self.stream = nil
            self.output = nil
            self.microphone?.stop()
            self.microphone = nil
            if let writer = self.writer {
                self.writer = nil
                try? await writer.finish()   // salvage what was written rather than lose it
            }
            self.onFailure?(error)
        }
    }
}
