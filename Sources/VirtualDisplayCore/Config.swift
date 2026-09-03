import Foundation

/// Where user customisation lives, so none of it needs a new build:
/// `~/.config/virtual-display/config.json` and `~/.config/virtual-display/plugins/*.lua`.
public enum ConfigPaths {
    public static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("virtual-display")
    }

    public static var file: URL { directory.appendingPathComponent("config.json") }
    public static var plugins: URL { directory.appendingPathComponent("plugins") }
}

/// The declarative half of customisation: extra presets, extra shortcuts, different
/// startup defaults. Anything needing logic is a Lua plugin instead.
///
/// A missing file is the normal case and a malformed one is logged and ignored: neither
/// may stop the app from launching, because a menu bar app that refuses to start over a
/// stray comma leaves the user nothing to fix it with.
public struct Config: Codable, Equatable, Sendable {

    /// `var`, because the settings window edits these in place.
    public struct Preset: Codable, Equatable, Sendable {
        public var name: String
        public var width: Double
        public var height: Double

        public init(name: String, width: Double, height: Double) {
            self.name = name
            self.width = width
            self.height = height
        }
    }

    public struct Defaults: Codable, Equatable, Sendable {
        /// Only consulted for settings the user has never toggled in the menu; once
        /// toggled, their choice wins and stays in `defaults read`.
        public var showsCursor: Bool?
        public var editRegion: Bool?
    }

    /// Where screenshots and recordings go. Absent means the system folders.
    public struct Captures: Codable, Equatable, Sendable {
        public var screenshots: String?
        public var recordings: String?
    }

    /// Appended to the built-in presets rather than replacing them.
    public var presets: [Preset] = []
    /// `"ctrl-opt-cmd-r": "snap-to-window-below"`. The value is a command, optionally with
    /// arguments: `"set-size?width=1280&height=720"`.
    public var hotkeys: [String: String] = [:]
    public var defaults: Defaults?
    public var captures: Captures?

    public init() {}

    public static func load(from url: URL = ConfigPaths.file) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("virtual-display: ignoring %@: %@", url.path, String(describing: error))
            return Config()
        }
    }

    /// Written by the settings window. Hand-editing and the UI share one file, so this
    /// rewrites it whole: JSON has no comments to lose, but any key this version does not
    /// know about goes away. Sorted keys and an indent keep the result diffable and
    /// hand-editable afterwards.
    public func save(to url: URL = ConfigPaths.file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Half-typed rows are normal while the settings window is open, so a preset only
    /// reaches the menu once it describes a size that can actually be applied.
    public var regionSizes: [RegionSize] {
        presets
            .filter { $0.width > 0 && $0.height > 0 && !$0.name.isEmpty }
            .map { RegionSize(name: $0.name, size: CGSize(width: $0.width, height: $0.height)) }
    }

    /// The commands the config binds a shortcut to, ignoring any arguments. A default
    /// shortcut for one of these stands down, so rebinding replaces rather than doubles.
    public var boundCommands: Set<String> {
        Set(hotkeys.values.map { String($0.prefix(while: { $0 != "?" })) })
    }
}
