/// Everything the UI is derived from. The rules that used to be spread across `syncUI`
/// live here as named, testable properties, so a new surface (a preferences window, a
/// second region) renders from the same source instead of re-deciding them.
public struct AppState: Equatable, Sendable {
    public var hasScreenRecordingAccess = false
    public var isMirroring = false
    /// Session-only, never persisted: a pause is something you undo within a meeting.
    public var isPaused = false
    public var isEditingRegion = true
    public var showsCursor = true
    public var isLoginItemEnabled = false

    public init() {}

    /// Capture runs exactly here. Every other path sets state and lets this decide.
    public var isCapturing: Bool { isMirroring && !isPaused }

    /// The output window exists solely to be shared, so it follows mirroring rather than
    /// being managed by hand. Pause deliberately keeps it up: hiding it would drop the
    /// meeting's selection, which is the opposite of what a pause is for.
    public var showsOutputWindow: Bool { isMirroring }

    /// Visible while you are placing it, or while mirroring makes it mark what is being
    /// shared. Neither, and it has nothing to say.
    public var showsRegionWindow: Bool { isMirroring || isEditingRegion }

    /// Locked means click-through, so the window you dragged into the region stays usable.
    public var regionAcceptsMouse: Bool { isEditingRegion }

    /// Conferencing apps build their "share a window" list from applications that have a
    /// Dock presence, so an agent app's windows are never offered. Being regular exactly
    /// while the shareable window is up is what gets it listed.
    public var wantsDockIcon: Bool { showsOutputWindow }

    /// Without the grant, mirroring is not merely refused on click: it is not offerable.
    public var canToggleMirroring: Bool { hasScreenRecordingAccess }

    /// Pause is meaningless with nothing running and must not look available then.
    public var canPause: Bool { isMirroring }
}
