import XCTest
@testable import VirtualDisplayCore

/// The visibility rules that used to be scattered through `syncUI`. These are the ones
/// that caused real bugs: a hidden output window is invisible to every share picker.
final class AppStateTests: XCTestCase {

    func testLaunchesIdleWithNothingToShare() {
        let state = AppState()
        XCTAssertFalse(state.isCapturing)
        XCTAssertFalse(state.showsOutputWindow)
        XCTAssertFalse(state.wantsDockIcon)
    }

    func testMirroringOpensTheShareableWindowAndTakesADockIcon() {
        var state = AppState()
        state.isMirroring = true
        XCTAssertTrue(state.isCapturing)
        XCTAssertTrue(state.showsOutputWindow)
        // Conferencing apps only list windows of apps with a Dock presence.
        XCTAssertTrue(state.wantsDockIcon)
    }

    /// Screenshot and recording both grab the output window, so both need it to exist.
    func testCapturingTheOutputNeedsTheOutputWindow() {
        var state = AppState()
        XCTAssertFalse(state.canCaptureOutput)
        state.isMirroring = true
        XCTAssertTrue(state.canCaptureOutput)
        // Paused still counts: freezing the picture and grabbing a still is reasonable.
        state.isPaused = true
        XCTAssertTrue(state.canCaptureOutput)
    }

    /// Without a Dock icon the settings window cannot be reached from the Dock or the
    /// app switcher, so pushing it behind something loses it.
    func testTheSettingsWindowTakesADockIcon() {
        var state = AppState()
        XCTAssertFalse(state.wantsDockIcon)
        state.isShowingSettings = true
        XCTAssertTrue(state.wantsDockIcon)
        // And closing it goes back to tray-only, unless mirroring keeps it.
        state.isShowingSettings = false
        XCTAssertFalse(state.wantsDockIcon)
    }

    func testPauseStopsCaptureButKeepsTheWindowOnScreen() {
        var state = AppState()
        state.isMirroring = true
        state.isPaused = true
        XCTAssertFalse(state.isCapturing)
        // Hiding it would drop the meeting's selection, which defeats the point of pause.
        XCTAssertTrue(state.showsOutputWindow)
        XCTAssertTrue(state.wantsDockIcon)
    }

    func testStoppingMirroringClosesTheWindow() {
        var state = AppState()
        state.isMirroring = false
        state.isPaused = true
        XCTAssertFalse(state.isCapturing)
        XCTAssertFalse(state.showsOutputWindow)
    }

    func testRegionFrameShowsWhileEditingWithoutMirroring() {
        var state = AppState()
        state.isEditingRegion = true
        XCTAssertTrue(state.showsRegionWindow)
        XCTAssertTrue(state.regionAcceptsMouse)
    }

    func testLockedRegionIsClickThroughButStillVisibleWhileMirroring() {
        var state = AppState()
        state.isMirroring = true
        state.isEditingRegion = false
        XCTAssertTrue(state.showsRegionWindow)
        XCTAssertFalse(state.regionAcceptsMouse)
    }

    func testIdleAndLockedHidesTheRegionFrame() {
        var state = AppState()
        state.isMirroring = false
        state.isEditingRegion = false
        XCTAssertFalse(state.showsRegionWindow)
    }

    func testMirroringIsNotOfferableWithoutTheGrant() {
        var state = AppState()
        state.hasScreenRecordingAccess = false
        XCTAssertFalse(state.canToggleMirroring)
    }

    func testPauseIsNotOfferableWithNothingRunning() {
        XCTAssertFalse(AppState().canPause)
    }
}
