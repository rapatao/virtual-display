import AVFoundation
import XCTest
@testable import VirtualDisplayCore

final class CaptureFilesTests: XCTestCase {

    func testNamesFilesTheWayMacOSDoes() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        components.hour = 22; components.minute = 15; components.second = 0
        let date = Calendar(identifier: .gregorian).date(from: components)!
        // No colons: legal in a file name, but Finder shows them as slashes.
        XCTAssertEqual(CaptureFiles.stamp(date), "2026-09-03 at 22.15.00")
    }

    func testLandsInThePicturesAndMoviesFolders() throws {
        let png = try CaptureFiles.screenshot()
        let mov = try CaptureFiles.recording()
        XCTAssertEqual(png.pathExtension, "png")
        XCTAssertEqual(mov.pathExtension, "mov")
        XCTAssertEqual(png.deletingLastPathComponent().lastPathComponent, "Virtual Display")
        XCTAssertTrue(png.path.contains("/Pictures/"), png.path)
        XCTAssertTrue(mov.path.contains("/Movies/"), mov.path)
        // The folder is created up front, so writing cannot fail for want of it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.deletingLastPathComponent().path))
    }
}

/// The writer is where a recording is lost: an unfinalised .mov will not play, and a
/// half-written one is worse than none. Fed synthetic frames, headless.
final class SampleWriterTests: XCTestCase {

    private func temporaryURL() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func frame(at time: CMTime, size: CGSize) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = try XCTUnwrap(pixels)

        var info: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &info)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: buffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: try XCTUnwrap(info),
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// A second of silence, which is all the writer needs to prove it encodes what the
    /// microphone hands it.
    private func silence(at time: CMTime, frames: Int = 1024) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)

        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: 0, blockBufferOut: &block)
        let buffer = try XCTUnwrap(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: buffer, offsetIntoDestination: 0,
                                   dataLength: bytes)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
                                  formatDescription: try XCTUnwrap(format),
                                  sampleCount: frames, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// Sound arrives on its own queue, often before the first frame. The session starts at
    /// the first video sample, and an audio sample older than that is refused outright, so
    /// anything earlier has to be dropped rather than kill the recording.
    func testRecordsAudioAndDropsWhatArrivesBeforeTheFirstFrame() async throws {
        let url = temporaryURL()
        let size = CGSize(width: 320, height: 180)
        let writer = try SampleWriter(url: url, size: size, audioSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
        ])

        // Before anything: nothing to append to yet.
        writer.appendAudio(try silence(at: CMTime(value: -44100, timescale: 44100)))

        for index in 0..<15 {
            writer.append(try frame(at: CMTime(value: CMTimeValue(index), timescale: 30), size: size))
            writer.appendAudio(try silence(at: CMTime(value: CMTimeValue(index * 1470), timescale: 44100)))
        }
        try await writer.finish()

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let recorded = try await audio.first?.load(.timeRange).duration.seconds ?? 0
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1, "the microphone track is missing from the recording")
        XCTAssertGreaterThan(recorded, 0)
    }

    func testWritesAPlayableMovie() async throws {
        let url = temporaryURL()
        let size = CGSize(width: 320, height: 180)
        let writer = try SampleWriter(url: url, size: size)

        for index in 0..<15 {
            writer.append(try frame(at: CMTime(value: CMTimeValue(index), timescale: 30), size: size))
        }
        try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    /// Stopping a recording that never got a frame must leave no unplayable stub behind.
    func testAnEmptyRecordingReportsItselfAndLeavesNoFile() async throws {
        let url = temporaryURL()
        let writer = try SampleWriter(url: url, size: CGSize(width: 320, height: 180))

        do {
            try await writer.finish()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CaptureFailure, .noFrames)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

extension CaptureFailure: @retroactive Equatable {
    public static func == (lhs: CaptureFailure, rhs: CaptureFailure) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
