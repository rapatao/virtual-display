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
