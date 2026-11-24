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
final class OutputWindowDisplayTests: XCTestCase {

    func testFillsTheGivenScreenAsABorderlessWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OutputWindow(displayScreen: screen)
        window.canvasChanged()

        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertEqual(window.title, "Virtual Display")
        XCTAssertEqual(window.styleMask, [.borderless])
        XCTAssertEqual(window.level, OutputWindow.displayLevel)
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.mainMenu.rawValue)
        XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        XCTAssertEqual(window.frameAutosaveName, "")
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    func testParkingIsIgnoredForAWindowOpenedWhileSharingAsADisplay() throws {
        let savedCanvas = OutputCanvas.size
        let savedPark = Preferences.parksOutputWindow
        let savedShare = Preferences.sharesAsDisplay
        defer {
            OutputCanvas.size = savedCanvas
            Preferences.parksOutputWindow = savedPark
            Preferences.sharesAsDisplay = savedShare
        }
        OutputCanvas.size = CGSize(width: 320, height: 180)
        Preferences.parksOutputWindow = true
        Preferences.sharesAsDisplay = true

        let window = OutputWindow()
        let visible = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 10, y: visible.maxY - 10))
        window.canvasChanged()
        XCTAssertTrue(visible.contains(window.frame))
    }

    func testIgnoresParkingAndKeepsItsFrame() throws {
        let saved = Preferences.parksOutputWindow
        defer { Preferences.parksOutputWindow = saved }
        Preferences.parksOutputWindow = true
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OutputWindow(displayScreen: screen)
        window.canvasChanged()
        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertEqual(window.constrainFrameRect(screen.frame, to: nil), screen.frame)
    }

    func testShowOrdersTheDisplayWindowInWithoutTakingFocus() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OutputWindow(displayScreen: screen)
        window.show()
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
    }

    func testRefitRestoresTheScreenFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OutputWindow(displayScreen: screen)
        window.setFrame(NSRect(x: 0, y: 0, width: 100, height: 100), display: false)
        window.refitToDisplay()
        XCTAssertEqual(window.frame, screen.frame)
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

    func testRevealBringsAParkedWindowOnScreenAndKeepsItThere() throws {
        let savedCanvas = OutputCanvas.size
        let savedPark = Preferences.parksOutputWindow
        let savedShare = Preferences.sharesAsDisplay
        defer {
            OutputCanvas.size = savedCanvas
            Preferences.parksOutputWindow = savedPark
            Preferences.sharesAsDisplay = savedShare
        }
        OutputCanvas.size = CGSize(width: 320, height: 180)
        Preferences.parksOutputWindow = true
        Preferences.sharesAsDisplay = false

        let window = OutputWindow()
        window.canvasChanged()
        let visible = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        let centre = { NSPoint(x: window.frame.midX, y: window.frame.midY) }
        XCTAssertFalse(visible.contains(centre()))

        window.reveal()
        defer {
            window.orderOut(nil)
            window.close()
        }
        XCTAssertTrue(visible.contains(centre()))
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)

        window.canvasChanged()
        XCTAssertTrue(visible.contains(centre()))
    }

    func testRevealedWindowParksAgainAndCloseCancelsThat() throws {
        let savedCanvas = OutputCanvas.size
        let savedPark = Preferences.parksOutputWindow
        let savedShare = Preferences.sharesAsDisplay
        defer {
            OutputCanvas.size = savedCanvas
            Preferences.parksOutputWindow = savedPark
            Preferences.sharesAsDisplay = savedShare
        }
        OutputCanvas.size = CGSize(width: 320, height: 180)
        Preferences.parksOutputWindow = true
        Preferences.sharesAsDisplay = false

        let window = OutputWindow()
        window.canvasChanged()
        let visible = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        let centre = { NSPoint(x: window.frame.midX, y: window.frame.midY) }

        window.reveal()
        XCTAssertTrue(visible.contains(centre()))
        XCTAssertNotNil(window.pendingRepark)

        window.repark()
        XCTAssertFalse(visible.contains(centre()))
        XCTAssertNil(window.pendingRepark)

        window.reveal()
        let revealed = window.frame
        window.close()
        XCTAssertNil(window.pendingRepark)
        XCTAssertEqual(window.frame, revealed)
    }

    func testRevealOnStartNeedsAParkedWindowOffADisplayAndTheSetting() {
        let decide = OutputWindow.shouldRevealOnStart
        XCTAssertTrue(decide(true, false, true))
        XCTAssertFalse(decide(false, false, true))
        XCTAssertFalse(decide(true, true, true))
        XCTAssertFalse(decide(true, false, false))
    }

    func testRevealPreferencesDefaultAndClamp() {
        let defaults = UserDefaults.standard
        let keys = [Preferences.Key.revealOnStart.rawValue, Preferences.Key.revealSeconds.rawValue]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { zip(keys, saved).forEach { defaults.set($1, forKey: $0) } }
        keys.forEach(defaults.removeObject(forKey:))

        XCTAssertTrue(Preferences.revealsOnStart)
        XCTAssertEqual(Preferences.revealSeconds, 30)
        Preferences.revealSeconds = 1
        XCTAssertEqual(Preferences.revealSeconds, 5)
        Preferences.revealSeconds = 9999
        XCTAssertEqual(Preferences.revealSeconds, 300)
        Preferences.revealSeconds = 45
        XCTAssertEqual(Preferences.revealSeconds, 45)
    }

    func testAReparkIsNeverScheduledOnADisplay() throws {
        let window = OutputWindow(displayScreen: try XCTUnwrap(NSScreen.main))
        defer { window.close() }
        window.scheduleRepark()
        XCTAssertNil(window.pendingRepark)
    }

    func testAReparkWaitsWhileAMouseButtonIsDown() {
        XCTAssertTrue(OutputWindow.shouldPostponeRepark(pressedButtons: 1))
        XCTAssertFalse(OutputWindow.shouldPostponeRepark(pressedButtons: 0))
    }

    func testRevealRaisesTheWindowAboveTheRegionFrameAndReparkRestoresIt() {
        let regionLevel = NSWindow.Level.floating.rawValue
        let toolbarLevel = regionLevel + 1
        XCTAssertGreaterThan(OutputWindow.revealedLevel.rawValue, toolbarLevel)

        let savedPark = Preferences.parksOutputWindow
        let savedShare = Preferences.sharesAsDisplay
        defer {
            Preferences.parksOutputWindow = savedPark
            Preferences.sharesAsDisplay = savedShare
        }
        Preferences.parksOutputWindow = true
        Preferences.sharesAsDisplay = false
        let window = OutputWindow()
        let original = window.level
        window.reveal()
        defer {
            window.orderOut(nil)
            window.close()
        }
        XCTAssertEqual(window.level, OutputWindow.revealedLevel)
        window.repark()
        XCTAssertEqual(window.level, original)
    }

    func testCloseRestoresTheLevelOfARevealedWindow() {
        let window = OutputWindow()
        window.reveal()
        window.close()
        XCTAssertEqual(window.level, .normal)
        XCTAssertNil(window.pendingRepark)
    }

    func testSchedulingLeavesADisplayWindowAtItsLevel() throws {
        let window = OutputWindow(displayScreen: try XCTUnwrap(NSScreen.main))
        defer { window.close() }
        window.scheduleRepark()
        XCTAssertEqual(window.level, OutputWindow.displayLevel)
    }

    func testRevealOfAnUnparkedWindowStillRestoresItsLevelLater() {
        let savedPark = Preferences.parksOutputWindow
        let savedShare = Preferences.sharesAsDisplay
        defer {
            Preferences.parksOutputWindow = savedPark
            Preferences.sharesAsDisplay = savedShare
        }
        Preferences.parksOutputWindow = false
        Preferences.sharesAsDisplay = false
        let window = OutputWindow()
        window.reveal()
        defer { window.close() }
        XCTAssertNotNil(window.pendingRepark)
        window.repark()
        XCTAssertEqual(window.level, .normal)
    }
}
