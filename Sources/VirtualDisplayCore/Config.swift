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

    public struct Preset: Codable, Equatable, Sendable {
        public let name: String
        public let width: Double
        public let height: Double
    }

    public struct Defaults: Codable, Equatable, Sendable {
        /// Only consulted for settings the user has never toggled in the menu; once
        /// toggled, their choice wins and stays in `defaults read`.
        public var showsCursor: Bool?
        public var editRegion: Bool?
    }

    /// Appended to the built-in presets rather than replacing them.
    public var presets: [Preset] = []
    /// `"ctrl-opt-cmd-r": "snap-to-window-below"`. The value is a command, optionally with
    /// arguments: `"set-size?width=1280&height=720"`.
    public var hotkeys: [String: String] = [:]
    public var defaults: Defaults?

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

    public var regionSizes: [RegionSize] {
        presets.map { RegionSize(name: $0.name, size: CGSize(width: $0.width, height: $0.height)) }
    }
}
