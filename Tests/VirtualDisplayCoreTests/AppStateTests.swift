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
