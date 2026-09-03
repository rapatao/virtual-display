import Foundation
import ServiceManagement

/// Every persisted setting, in one place, so `defaults read com.rapatao.virtual-display`
/// has a single authority. Window frames are not here: AppKit owns those through
/// `setFrameAutosaveName`.
public enum Preferences {
    private static let defaults = UserDefaults.standard

    public enum Key: String, CaseIterable {
        case editRegion
        case showsCursor
        case didRequestScreenRecordingAccess
    }

    /// `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell "absent"
    /// from "false", and both of these default to true.
    private static func bool(_ key: Key, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private static func set(_ value: Bool, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    public static var isEditingRegion: Bool {
        get { bool(.editRegion, default: true) }
        set { set(newValue, .editRegion) }
    }

    public static var showsCursor: Bool {
        get { bool(.showsCursor, default: true) }
        set { set(newValue, .showsCursor) }
    }

    /// macOS shows its Screen Recording dialog exactly once per app, ever, and offers no
    /// API to ask whether that has happened. Remembering it is what stops us stacking our
    /// own alert on top of the system one.
    public static var didRequestScreenRecordingAccess: Bool {
        get { bool(.didRequestScreenRecordingAccess, default: false) }
        set { set(newValue, .didRequestScreenRecordingAccess) }
    }
}

/// Launch at login. Lives in macOS rather than in our defaults, so `defaults delete`
/// will not clear it.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws for a build run straight out of `.build`: registration needs a real app
    /// bundle in a stable location.
    public static func toggle() throws {
        if isEnabled {
            try SMAppService.mainApp.unregister()
        } else {
            try SMAppService.mainApp.register()
        }
    }
}
