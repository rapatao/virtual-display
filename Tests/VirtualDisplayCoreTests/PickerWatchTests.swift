import XCTest
@testable import VirtualDisplayCore

final class PickerBannerTests: XCTestCase {
    private func matches(ownerPID: Int32 = 10, layer: Int = 25, width: Double = 426,
                         height: Double = 60, onScreen: Bool = true) -> Bool {
        PickerBanner.matches(ownerPID: ownerPID, ownPID: 1, layer: layer,
                             width: width, height: height, onScreen: onScreen)
    }

    func testMatchesTheBannerSeenWithChrome() {
        XCTAssertTrue(matches())
    }

    func testRejectsOurOwnWindows() {
        XCTAssertFalse(matches(ownerPID: 1))
    }

    func testRejectsOtherLayers() {
        XCTAssertFalse(matches(layer: 0))
        XCTAssertFalse(matches(layer: 24))
    }

    func testRejectsStripsOfTheWrongSize() {
        XCTAssertFalse(matches(width: 299))
        XCTAssertFalse(matches(width: 601))
        XCTAssertFalse(matches(height: 39))
        XCTAssertFalse(matches(height: 101))
    }

    func testRejectsOffScreenWindows() {
        XCTAssertFalse(matches(onScreen: false))
    }

    func testReadsWindowListEntries() {
        let banner: [String: Any] = [
            kCGWindowOwnerPID as String: Int32(10), kCGWindowLayer as String: 25,
            kCGWindowBounds as String: ["Width": 426.0, "Height": 60.0],
        ]
        XCTAssertTrue(PickerBanner.isShown(in: [banner], ownPID: 1))
        XCTAssertFalse(PickerBanner.isShown(in: [], ownPID: 1))
        XCTAssertFalse(PickerBanner.isShown(in: [banner], ownPID: 10))
    }
}

final class PickerWatchTests: XCTestCase {
    func testNeverSeenNeverParks() {
        var watch = PickerWatch()
        for _ in 0..<10 { XCTAssertFalse(watch.poll(bannerShown: false, age: 60)) }
        XCTAssertFalse(watch.seen)
    }

    func testSeenThenTwoMissesParks() {
        var watch = PickerWatch()
        XCTAssertFalse(watch.poll(bannerShown: true, age: 5))
        XCTAssertFalse(watch.poll(bannerShown: false, age: 6))
        XCTAssertTrue(watch.poll(bannerShown: false, age: 7))
    }

    func testOneMissIsAFlicker() {
        var watch = PickerWatch()
        XCTAssertFalse(watch.poll(bannerShown: true, age: 5))
        XCTAssertFalse(watch.poll(bannerShown: false, age: 6))
        XCTAssertFalse(watch.poll(bannerShown: true, age: 7))
        XCTAssertFalse(watch.poll(bannerShown: false, age: 8))
    }

    func testDoesNotParkBeforeTheMinimumAge() {
        var watch = PickerWatch()
        XCTAssertFalse(watch.poll(bannerShown: true, age: 0.5))
        XCTAssertFalse(watch.poll(bannerShown: false, age: 1))
        XCTAssertFalse(watch.poll(bannerShown: false, age: 1.5))
        XCTAssertTrue(watch.poll(bannerShown: false, age: PickerWatch.minimumAge))
    }

    func testParkWhenPickerClosesIsOnByDefault() {
        let key = Preferences.Key.parkWhenPickerCloses.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Preferences.parksWhenPickerCloses)
    }
}
