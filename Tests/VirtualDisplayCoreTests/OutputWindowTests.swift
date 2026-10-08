import XCTest
@testable import VirtualDisplayCore

/// The window a meeting shares. Two things matter here and they pull against each other:
/// it must look like a display (no chrome), and it must stay listable in a share picker.
@MainActor
final class OutputWindowTests: XCTestCase {

    func testKeepsATitleEvenThoughNoTitleBarIsDrawn() {
        let window = OutputWindow()
        // The picker lists this window by its title; an untitled window is one some
        // pickers drop entirely. Hiding the bar must never mean clearing the name.
        XCTAssertEqual(window.title, "Virtual Display")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.titled))
    }

    func testTheVideoFillsTheWholeWindowWithNoChrome() {
        let window = OutputWindow()
        let content = try? XCTUnwrap(window.contentView)
        // .fullSizeContentView: the content view is the whole frame, title bar included,
        // so nothing but picture is captured.
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(content?.frame.height, window.frame.height)
        XCTAssertEqual(content?.frame.width, window.frame.width)

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotEqual(window.standardWindowButton(button)?.isHidden, false)
        }
    }

    /// A minimised window reports onscreen=false and drops out of every picker, and
    /// closing it while mirroring runs would end the share.
    func testCannotBeMinimisedOrClosed() {
        let window = OutputWindow()
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.closable))
    }

    /// The title bar used to be the drag handle. With it gone, the picture has to be one.
    func testStaysMovableAndResizable() {
        let window = OutputWindow()
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }
}

@MainActor
final class OutputWindowSizeTests: XCTestCase {

    /// Anything smaller than one canvas pixel per backing pixel is shared upscaled.
    func testOpensAtOneToOneWithTheCanvas() throws {
        let saved = OutputCanvas.size
        defer { OutputCanvas.size = saved }
        OutputCanvas.size = CGSize(width: 320, height: 180)
        let window = OutputWindow()
        window.canvasChanged()
        let scale = (window.screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        let pixels = window.convertToBacking(try XCTUnwrap(window.contentView).bounds).size
        XCTAssertEqual(pixels.width, 320, accuracy: scale)
        XCTAssertEqual(pixels.height, 180, accuracy: scale)
    }
}

@MainActor
final class OutputWindowParkTests: XCTestCase {

    /// A picker drops a window with no part on a display, so a parked one keeps a corner.
    func testParkedWindowKeepsOnlyACornerOnScreen() throws {
        let savedCanvas = OutputCanvas.size
        let savedPark = Preferences.parksOutputWindow
        defer {
            OutputCanvas.size = savedCanvas
            Preferences.parksOutputWindow = savedPark
        }
        OutputCanvas.size = CGSize(width: 320, height: 180)
        Preferences.parksOutputWindow = true

        let window = OutputWindow()
        window.canvasChanged()
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let visible = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        let onScreen = window.frame.intersection(visible)
        XCTAssertEqual(onScreen.width, OutputWindow.parkedVisible, accuracy: 1)
        XCTAssertEqual(onScreen.height, OutputWindow.parkedVisible, accuracy: 1)
    }
}
