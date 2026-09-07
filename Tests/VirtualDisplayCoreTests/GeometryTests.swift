import CoreGraphics
import XCTest
@testable import VirtualDisplayCore

/// The coordinate maths, which is the only part of the app that can be wrong silently:
/// a bad conversion just puts the capture rectangle somewhere plausible but incorrect.
final class GeometryTests: XCTestCase {

    func testFlipsToDisplaySpaceOnPrimary() {
        // A region 200pt up from the bottom of a 1440pt screen is 700pt down from the top.
        XCTAssertEqual(
            Geometry.sourceRect(appKitRect: CGRect(x: 100, y: 200, width: 960, height: 540),
                                primaryHeight: 1440, displayOrigin: .zero),
            CGRect(x: 100, y: 700, width: 960, height: 540))
    }

    func testFlipsRegionFlushToBottomLeft() {
        XCTAssertEqual(
            Geometry.sourceRect(appKitRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                primaryHeight: 1000, displayOrigin: .zero),
            CGRect(x: 0, y: 900, width: 100, height: 100))
    }

    func testSubtractsOriginOfDisplayLeftOfPrimary() {
        // A display to the left of primary has a negative CG origin, so a region at
        // AppKit x = -1600 sits at x = 0 on that display.
        XCTAssertEqual(
            Geometry.sourceRect(appKitRect: CGRect(x: -1600, y: 400, width: 800, height: 600),
                                primaryHeight: 1440, displayOrigin: CGPoint(x: -1600, y: 0)),
            CGRect(x: 0, y: 440, width: 800, height: 600))
    }

    func testAppKitConversionIsExactInverse() {
        // Drift here would compound on every snap to a window.
        let start = CGRect(x: 120, y: 340, width: 640, height: 400)
        let there = Geometry.sourceRect(appKitRect: start, primaryHeight: 1440, displayOrigin: .zero)
        XCTAssertEqual(Geometry.appKitRect(fromCG: there, primaryHeight: 1440), start)
    }

    // MARK: Clamping

    private let visible = CGRect(x: 0, y: 80, width: 1920, height: 963)

    func testInBoundsFrameIsUntouched() {
        let inside = CGRect(x: 400, y: 300, width: 960, height: 540)
        XCTAssertEqual(Geometry.clamp(inside, into: visible), inside)
    }

    func testOffScreenFrameSlidesBackKeepingItsSize() {
        XCTAssertEqual(
            Geometry.clamp(CGRect(x: 1800, y: -200, width: 960, height: 540), into: visible),
            CGRect(x: 960, y: 80, width: 960, height: 540))
    }

    func testOversizedFrameShrinksBeforeTheOriginIsClamped() {
        // Without the shrink-first order the origin clamp produces a negative x.
        XCTAssertEqual(
            Geometry.clamp(CGRect(x: 500, y: 500, width: 3000, height: 2000), into: visible),
            visible)
    }

    // MARK: Presets

    func testResizeKeepsTheTopEdgeFixed() {
        // Resizing around AppKit's bottom-left origin would make the frame jump upward.
        let frame = CGRect(x: 10, y: 100, width: 400, height: 300)
        let resized = Geometry.resizedFromTop(frame, to: CGSize(width: 200, height: 100))
        XCTAssertEqual(resized.maxY, frame.maxY)
        XCTAssertEqual(resized, CGRect(x: 10, y: 300, width: 200, height: 100))
    }

    // MARK: Aspect lock

    func testFittingOnlyShrinksAndKeepsTheTopEdge() {
        let canvas = CGSize(width: 16, height: 9)
        // Too tall: the height goes, and the frame grows downward from where it was.
        let tall = CGRect(x: 10, y: 100, width: 1600, height: 1200)
        let fitted = Geometry.fit(tall, aspect: canvas)
        XCTAssertEqual(fitted, CGRect(x: 10, y: 400, width: 1600, height: 900))
        XCTAssertEqual(fitted.maxY, tall.maxY)

        // Too wide: the width goes instead. Either way nothing gets bigger, which is what
        // keeps a fitted frame inside the screen a clamp just put it on.
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 900)
        XCTAssertEqual(Geometry.fit(wide, aspect: canvas), CGRect(x: 0, y: 0, width: 1600, height: 900))
    }

    func testFittingAFrameAlreadyOnRatioChangesNothing() {
        let already = CGRect(x: 5, y: 5, width: 1920, height: 1080)
        XCTAssertEqual(Geometry.fit(already, aspect: CGSize(width: 16, height: 9)), already)
        // A canvas that is not 16:9 is still just a ratio.
        XCTAssertEqual(Geometry.fit(CGRect(x: 0, y: 0, width: 400, height: 400),
                                    aspect: CGSize(width: 1, height: 2)),
                       CGRect(x: 0, y: 0, width: 200, height: 400))
    }

    func testFittingSurvivesDegenerateInput() {
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(Geometry.fit(empty, aspect: CGSize(width: 16, height: 9)), empty)
        XCTAssertEqual(Geometry.fit(visible, aspect: .zero), visible)
    }

    // MARK: Two displays

    /// Capture is built from a single display, so a region across two of them silently
    /// fills the other half with whatever is at that rectangle on the first.
    func testSpansDisplaysOnlyWhenItActuallyOverlapsTwo() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let screens = [left, right]

        XCTAssertFalse(Geometry.spansDisplays(CGRect(x: 100, y: 100, width: 960, height: 540),
                                              screens: screens))
        XCTAssertTrue(Geometry.spansDisplays(CGRect(x: 1600, y: 100, width: 960, height: 540),
                                             screens: screens))
        // Flush against the boundary is not overlapping it.
        XCTAssertFalse(Geometry.spansDisplays(CGRect(x: 960, y: 0, width: 960, height: 540),
                                              screens: screens))
        // One screen cannot be spanned.
        XCTAssertFalse(Geometry.spansDisplays(CGRect(x: 1600, y: 100, width: 960, height: 540),
                                              screens: [left]))
    }

    func testEveryAnchorLandsInsideTheVisibleArea() {
        let size = CGSize(width: 400, height: 225)
        for spot in RegionSpot.allCases {
            let origin = Geometry.origin(for: spot, size: size, in: visible)
            let placed = CGRect(origin: origin, size: size)
            XCTAssertTrue(visible.contains(placed), "\(spot.name) escaped the screen: \(placed)")
        }
    }

    func testHalfScreenPresetIsSixteenByNine() {
        let size = RegionSize(name: "Half Screen", size: nil).resolved(in: visible)
        XCTAssertEqual(size.width, visible.width / 2)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
    }
}
