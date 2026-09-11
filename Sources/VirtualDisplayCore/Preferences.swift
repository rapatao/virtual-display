import Foundation
import ServiceManagement

/// Every persisted setting, in one place, so `defaults read com.rapatao.virtual-display`
/// has a single authority. Window frames are not here: AppKit owns those through
/// `setFrameAutosaveName`.
public enum Preferences {
    private static let defaults = UserDefaults.standard

    public enum Key: String, CaseIterable {
        case editRegion
        case followFocus
        case showsCursor
        case lockAspect
        case didRequestScreenRecordingAccess
        case enablePlugins
        case requireAutomationToken
        case automationToken
        case automationGrants
    }

    /// Startup values for settings the user has never toggled, supplied by the config
    /// file. Set once at launch, before anything reads a preference.
    public struct Fallbacks {
        public var isEditingRegion = true
        public var followsFocus = false
        public var showsCursor = true
        public var locksAspect = false
        public init() {}
    }

    public static var fallbacks = Fallbacks()

    /// `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell "absent"
    /// from "false", which is what lets a config default apply only until the user makes
    /// their own choice in the menu.
    private static func bool(_ key: Key, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private static func set(_ value: Bool, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    public static var isEditingRegion: Bool {
        get { bool(.editRegion, default: fallbacks.isEditingRegion) }
        set { set(newValue, .editRegion) }
    }

    public static var followsFocus: Bool {
        get { bool(.followFocus, default: fallbacks.followsFocus) }
        set { set(newValue, .followFocus) }
    }

    public static var showsCursor: Bool {
        get { bool(.showsCursor, default: fallbacks.showsCursor) }
        set { set(newValue, .showsCursor) }
    }

    /// Holds the region to the output canvas's shape, so nothing is letterboxed.
    public static var locksAspect: Bool {
        get { bool(.lockAspect, default: fallbacks.locksAspect) }
        set { set(newValue, .lockAspect) }
    }

    /// Off until asked for, and deliberately so. A plugin is arbitrary code running inside
    /// a process that holds Screen Recording, and anything able to write a file in the
    /// user's home can put one there. Loading them has to be a decision someone made.
    public static var pluginsEnabled: Bool {
        get { bool(.enablePlugins, default: false) }
        set { set(newValue, .enablePlugins) }
    }

    // MARK: Automation

    /// On by default. A token in the URL is the only thing a web page cannot supply, and
    /// the commands it guards are the ones worth guarding. Turning it off falls back to
    /// asking once per command, which is `automationGrants`.
    public static var requiresAutomationToken: Bool {
        get { bool(.requireAutomationToken, default: true) }
        set { set(newValue, .requireAutomationToken) }
    }

    /// Made on first read rather than at launch, so an app that is never automated never
    /// stores one. Replaced by the Regenerate button, which is what makes a token that
    /// leaked into shell history recoverable.
    public static var automationToken: String {
        get {
            if let stored = defaults.string(forKey: Key.automationToken.rawValue),
               !stored.isEmpty {
                return stored
            }
            let fresh = AutomationPolicy.freshToken()
            defaults.set(fresh, forKey: Key.automationToken.rawValue)
            return fresh
        }
        set { defaults.set(newValue, forKey: Key.automationToken.rawValue) }
    }

    /// What each command does when a URL asks for it, by command name. A command with no
    /// entry is on the default.
    ///
    /// Values that are not one of the rules are dropped rather than guessed at, so an
    /// unreadable entry fails to the default instead of to something permissive.
    public static var automationRules: [String: AutomationPolicy.Rule] {
        get {
            let stored = defaults.dictionary(forKey: Key.automationGrants.rawValue) ?? [:]
            return stored.compactMapValues { value in
                if let name = value as? String { return AutomationPolicy.Rule(rawValue: name) }
                // A boolean is how this was written before the rules had names.
                if let allowed = value as? Bool { return allowed ? .allow : .deny }
                return nil
            }
        }
        set {
            defaults.set(newValue.mapValues(\.rawValue), forKey: Key.automationGrants.rawValue)
        }
    }

    /// Everything the automation gate needs, read together so a decision is made from one
    /// consistent picture.
    public static var automationPolicy: AutomationPolicy {
        AutomationPolicy(requiresToken: requiresAutomationToken,
                         token: automationToken,
                         rules: automationRules)
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
