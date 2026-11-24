import AppKit
import XCTest
@testable import VirtualDisplayCore

@MainActor
final class VirtualScreenTests: XCTestCase {
    private func version(_ major: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
    }

    func testSupportedRange() {
        XCTAssertFalse(VirtualScreen.isSupported(version: version(13)))
        XCTAssertTrue(VirtualScreen.isSupported(version: version(14)))
        XCTAssertTrue(VirtualScreen.isSupported(version: version(27)))
        XCTAssertFalse(VirtualScreen.isSupported(version: version(28)))
    }

    func testModeFromCanvas() throws {
        let mode = try XCTUnwrap(VirtualScreen.mode(for: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(mode.width, 1920)
        XCTAssertEqual(mode.height, 1080)
        XCTAssertEqual(mode.refreshRate, 60)
        XCTAssertEqual(mode.sizeInMillimeters.width, 1920 * 25.4 / 110, accuracy: 0.001)
        XCTAssertEqual(mode.sizeInMillimeters.height, 1080 * 25.4 / 110, accuracy: 0.001)
    }

    func testModeRejectsInvalidCanvas() {
        XCTAssertNil(VirtualScreen.mode(for: CGSize(width: -1, height: 1080)))
        XCTAssertNil(VirtualScreen.mode(for: CGSize(width: 1920, height: 0)))
        XCTAssertNil(VirtualScreen.mode(for: CGSize(width: CGFloat.nan, height: 1080)))
        XCTAssertNil(VirtualScreen.mode(for: CGSize(width: CGFloat.infinity, height: 1080)))
    }

    func testCaptureNeverTargetsTheVirtualDisplay() {
        XCTAssertTrue(VirtualScreen.isVirtual(7, virtualID: 7))
        XCTAssertFalse(VirtualScreen.isVirtual(7, virtualID: 8))
        XCTAssertFalse(VirtualScreen.isVirtual(7, virtualID: nil))
        XCTAssertFalse(VirtualScreen.isVirtual(nil, virtualID: nil))
        XCTAssertNil(VirtualScreen.capturable(nil, excluding: 7))
    }

    func testRegionMovesToTheMainDisplayUnlessItIsVirtual() {
        XCTAssertEqual(VirtualScreen.realDisplayIndex(of: [9, 1, 2], virtualID: 9, mainID: 2), 2)
        XCTAssertEqual(VirtualScreen.realDisplayIndex(of: [2, 9], virtualID: 2, mainID: 2), 1)
        XCTAssertEqual(VirtualScreen.realDisplayIndex(of: [9, 5], virtualID: 9, mainID: 1), 1)
        XCTAssertNil(VirtualScreen.realDisplayIndex(of: [9], virtualID: 9, mainID: 1))
        XCTAssertNil(VirtualScreen.realDisplayIndex(of: [], virtualID: nil, mainID: 1))
    }

    func testDisplayIsLostWhenOfflineOrMirrored() {
        XCTAssertFalse(VirtualScreen.isLost(isOnline: true, isInMirrorSet: false, isMain: false))
        XCTAssertTrue(VirtualScreen.isLost(isOnline: false, isInMirrorSet: false, isMain: false))
        XCTAssertTrue(VirtualScreen.isLost(isOnline: true, isInMirrorSet: true, isMain: false))
        XCTAssertTrue(VirtualScreen.isLost(isOnline: true, isInMirrorSet: false, isMain: true))
    }

    func testStartFallsBackWhenTheDisplayCannotBeCreated() {
        var asked = 0
        let canvas = CGSize(width: 320, height: 180)
        let failing: (CGSize) -> VirtualScreen? = { _ in asked += 1; return nil }

        guard case .failed = VirtualScreen.start(wanted: true, canvas: canvas, make: failing) else {
            return XCTFail("a refused display must be reported as failed")
        }
        XCTAssertEqual(asked, 1)

        guard case .window = VirtualScreen.start(wanted: false, canvas: canvas, make: failing) else {
            return XCTFail("setting off must open a plain window")
        }
        XCTAssertEqual(asked, 1)
    }

    func testShareAsDisplayIsOffByDefault() {
        let key = Preferences.Key.shareAsDisplay.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Preferences.sharesAsDisplay)
    }

    func testCreateResizeAndRelease() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VD_VIRTUAL_DISPLAY_TESTS"] == "1")
        let canvas = OutputCanvas.standard
        let virtual = try XCTUnwrap(VirtualScreen(canvas: canvas))
        let id = virtual.displayID

        let screen = await virtual.screen()
        XCTAssertEqual(screen.map { $0.frame.size.width * $0.backingScaleFactor }, canvas.width)
        XCTAssertEqual(screen.map { $0.frame.size.height * $0.backingScaleFactor }, canvas.height)

        XCTAssertTrue(virtual.apply(canvas: CGSize(width: 1280, height: 720)))
        for _ in 0..<40 where CGDisplayPixelsWide(id) != 1280 || CGDisplayPixelsHigh(id) != 720 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(CGDisplayPixelsWide(id), 1280)
        XCTAssertEqual(CGDisplayPixelsHigh(id), 720)

        virtual.stop()
        for _ in 0..<40 where Self.isOnline(id) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(Self.isOnline(id))
    }

    private static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return ids.prefix(Int(count)).contains(id)
    }
}
