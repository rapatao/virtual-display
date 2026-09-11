/// Everything the UI is derived from. The rules that used to be spread across `syncUI`
/// live here as named, testable properties, so a new surface (a preferences window, a
/// second region) renders from the same source instead of re-deciding them.
/// `Codable` so the `state` command can hand the whole thing to a script as JSON without a
/// second, hand-maintained description of the same fields.
public struct AppState: Equatable, Sendable, Codable {
    public var hasScreenRecordingAccess = false
    public var isMirroring = false
    /// Session-only, never persisted: a pause is something you undo within a meeting.
    public var isPaused = false
    public var isEditingRegion = true
    /// The region tracks the window you are working in, wherever it goes.
    public var followsFocus = false
    public var showsCursor = true
    /// The region is held to the output canvas's aspect ratio, so nothing is letterboxed.
    public var locksRegionAspect = false
    /// The region covers more than one display, which capture cannot do. Read off the
    /// screens rather than chosen.
    public var regionSpansDisplays = false
    public var isLoginItemEnabled = false
    /// Session-only, like pause: a recording never survives a restart.
    public var isRecording = false
    /// Pause leaves the last frame in the shared window instead of blanking it. Read from
    /// the config file, kept here because what a pause looks like decides what a
    /// screenshot of it is worth.
    public var freezesOnPause = false
    /// Off until the user says otherwise: a plugin is arbitrary code with this app's
    /// Screen Recording grant.
    public var arePluginsEnabled = false
    /// Session-only: the settings window is open.
    public var isShowingSettings = false

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

    /// A pause freezes the picture, so it has to freeze what the picture is of too:
    /// following an app switch while paused would silently change what resumes.
    public var isFollowingFocus: Bool { followsFocus && !isPaused }

    /// Locked means click-through, so the window you dragged into the region stays usable.
    public var regionAcceptsMouse: Bool { isEditingRegion }

    /// Conferencing apps build their "share a window" list from applications that have a
    /// Dock presence, so an agent app's windows are never offered. Being regular exactly
    /// while the shareable window is up is what gets it listed.
    ///
    /// The settings window counts too: without a Dock icon it cannot be reached from the
    /// Dock or the app switcher, so pushing it behind something loses it.
    public var wantsDockIcon: Bool { showsOutputWindow || isShowingSettings }

    /// Without the grant, mirroring is not merely refused on click: it is not offerable.
    public var canToggleMirroring: Bool { hasScreenRecordingAccess }

    /// Pause is meaningless with nothing running and must not look available then.
    public var canPause: Bool { isMirroring }

    /// Both capture the output window, so both need it to exist. A pause counts only when
    /// it freezes: a blanked pause has nothing in that window but black, and a screenshot
    /// of it is a black PNG nobody asked for.
    public var canCaptureOutput: Bool { showsOutputWindow && (!isPaused || freezesOnPause) }
}
