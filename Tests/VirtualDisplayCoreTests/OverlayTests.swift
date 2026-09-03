import XCTest
@testable import VirtualDisplayCore

/// Overlay specs are written by hand in Lua or in a URL, so the parsing is where the
/// mistakes land: a silently ignored colour is worse than a complaint.
final class OverlayItemTests: XCTestCase {

    private func item(_ pairs: [String: String]) throws -> OverlayItem {
        try OverlayItem(CommandCenter.Arguments(pairs))
    }

    func testReadsAFullSpec() throws {
        let overlay = try item(["text": "recording", "x": "0.5", "y": "0.9", "size": "48",
                                "color": "#ff0000", "align": "center", "alpha": "0.8", "z": "3"])
        XCTAssertEqual(overlay.text, "recording")
        XCTAssertEqual(overlay.x, 0.5)
        XCTAssertEqual(overlay.y, 0.9)
        XCTAssertEqual(overlay.size, 48)
        XCTAssertEqual(overlay.alignment, .center)
        XCTAssertEqual(overlay.alpha, 0.8)
        XCTAssertEqual(overlay.z, 3)
        XCTAssertEqual(overlay.color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(overlay.color.greenComponent, 0, accuracy: 0.01)
    }

    func testColoursTakeHexShortHexAndNames() throws {
        XCTAssertEqual(try item(["text": "a", "color": "#fff"]).color.redComponent, 1, accuracy: 0.01)
        // Named colours come back in whatever colour space AppKit likes, hence the convert.
        let black = try XCTUnwrap(try item(["text": "a", "color": "black"]).color
            .usingColorSpace(.sRGB))
        XCTAssertEqual(black.redComponent, 0, accuracy: 0.01)
        let translucent = try item(["text": "a", "color": "#00000080"]).color
        XCTAssertEqual(translucent.alphaComponent, 0.5, accuracy: 0.01)
    }

    func testRejectsWhatItCannotDraw() {
        XCTAssertThrowsError(try item(["text": "a", "color": "burgundy"]))
        XCTAssertThrowsError(try item(["text": "a", "align": "sideways"]))
        XCTAssertThrowsError(try item(["text": "a", "size": "0"]))
        XCTAssertThrowsError(try item(["image": "/nonexistent/logo.png"]))
        // Nothing to draw and nothing to measure a rectangle from.
        XCTAssertThrowsError(try item(["x": "0.5"]))
        XCTAssertThrowsError(try item(["background": "black", "w": "0.5"]))
    }

    func testABackgroundWithASizeIsAValidRectangle() throws {
        let overlay = try item(["background": "#00000080", "w": "0.4", "h": "0.1"])
        XCTAssertNil(overlay.text)
        XCTAssertEqual(overlay.width, 0.4)
        XCTAssertEqual(overlay.height, 0.1)
    }

    /// A plugin computing a position from window geometry will overshoot at the edges.
    func testPositionsAreClampedRatherThanRejected() throws {
        let overlay = try item(["text": "a", "x": "1.4", "y": "-0.2"])
        XCTAssertEqual(overlay.x, 1)
        XCTAssertEqual(overlay.y, 0)
    }
}

@MainActor
final class OverlayViewTests: XCTestCase {

    private func text(_ string: String) throws -> OverlayItem {
        try OverlayItem(CommandCenter.Arguments(["text": string]))
    }

    func testSettingTheSameIdReplacesInPlace() throws {
        let view = OverlayView()
        view.set("clock", try text("12:00"))
        view.set("logo", try text("logo"))
        view.set("clock", try text("12:01"))
        // Order matters: a clock updating every second must not climb over its neighbour.
        XCTAssertEqual(view.ids, ["clock", "logo"])
    }

    func testNilRemovesAndClearingRemovesEverything() throws {
        let view = OverlayView()
        view.set("a", try text("a"))
        view.set("b", try text("b"))
        view.set("a", nil)
        XCTAssertEqual(view.ids, ["b"])
        view.removeAll()
        XCTAssertEqual(view.ids, [])
    }

    /// Clicks must reach the window underneath; the overlay is decoration only.
    func testTheOverlayNeverTakesAClick() {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
    }

    /// Drawing is where a bad rect or a nil font would crash; run it once for real.
    func testDrawingEveryKindOfItemDoesNotCrash() throws {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.set("text", try OverlayItem(CommandCenter.Arguments(
            ["text": "hello", "x": "0.5", "y": "0.5", "align": "center", "background": "black"])))
        view.set("rect", try OverlayItem(CommandCenter.Arguments(
            ["background": "#00000080", "w": "0.3", "h": "0.1", "z": "-1"])))

        let image = NSImage(size: NSSize(width: 1920, height: 1080))
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }
}

final class FetchRequestTests: XCTestCase {

    func testReadsMethodBodyTimeoutAndFlattenedHeaders() {
        let request = FetchRequest(url: "https://example.com", options: [
            "method": "post", "body": "{}", "timeout": "5",
            "header.Authorization": "Bearer x", "header.Accept": "application/json",
        ])
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, "{}")
        XCTAssertEqual(request.timeout, 5)
        XCTAssertEqual(request.headers, ["Authorization": "Bearer x", "Accept": "application/json"])
    }

    func testDefaultsToAPlainGet() {
        let request = FetchRequest(url: "https://example.com", options: [:])
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.timeout, 15)
    }

    /// No file:// or custom schemes: a plugin that wants a local file has `io`.
    func testNonHttpUrlsAreRefusedWithoutATask() {
        let expectation = expectation(description: "completion")
        Fetch.send(FetchRequest(url: "file:///etc/passwd")) { body, status, error in
            XCTAssertNil(body)
            XCTAssertEqual(status, 0)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
