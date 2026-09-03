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
