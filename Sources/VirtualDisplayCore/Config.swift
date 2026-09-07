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
        /// Optional position in screen points. Both together move the region as well as
        /// resizing it; either one missing resizes in place, as the built-in sizes do.
        public var x: Double?
        public var y: Double?

        public init(name: String, width: Double, height: Double,
                    x: Double? = nil, y: Double? = nil) {
            self.name = name
            self.width = width
            self.height = height
            self.x = x
            self.y = y
        }
    }

    public struct Defaults: Codable, Equatable, Sendable {
        /// Only consulted for settings the user has never toggled in the menu; once
        /// toggled, their choice wins and stays in `defaults read`.
        public var showsCursor: Bool?
        public var editRegion: Bool?
        public var followFocus: Bool?
        public var lockAspect: Bool?
    }

    /// Where screenshots and recordings go. Absent means the system folders.
    public struct Captures: Codable, Equatable, Sendable {
        public var screenshots: String?
        public var recordings: String?
        /// Record the microphone alongside the picture. Off unless turned on.
        public var microphone: Bool?
    }

    /// The pixel canvas the mirror, screenshots and recordings are produced at. A region
    /// larger than this is downsampled; a larger canvas keeps the detail and costs
    /// encoding work.
    public struct Output: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// Appended to the built-in presets rather than replacing them.
    public var presets: [Preset] = []
    /// `"ctrl-opt-cmd-r": "snap-to-window-below"`. The value is a command, optionally with
    /// arguments: `"set-size?width=1280&height=720"`.
    public var hotkeys: [String: String] = [:]
    public var defaults: Defaults?
    public var captures: Captures?
    public var output: Output?
    /// Pause leaves the last frame on screen instead of blanking the share.
    public var freezeOnPause: Bool?
    /// Apps that follow mode leaves alone: the meeting app itself, a password manager,
    /// anything you switch to mid-call without wanting it on the call.
    public var followIgnores: [String] = []
    /// Plugin file names left unloaded while the rest still run, as `10-clock.lua`.
    public var disabledPlugins: [String] = []

    public init() {}

    /// A hand-written file leaves most keys out, and a synthesized decoder treats a
    /// missing key as an error even where the property has a default: without this, a
    /// file with no `presets` is thrown away whole, taking the keys it did have with it,
    /// and adding any key here would discard every config written before it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? []
        hotkeys = try container.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? [:]
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults)
        captures = try container.decodeIfPresent(Captures.self, forKey: .captures)
        output = try container.decodeIfPresent(Output.self, forKey: .output)
        freezeOnPause = try container.decodeIfPresent(Bool.self, forKey: .freezeOnPause)
        followIgnores = try container.decodeIfPresent([String].self, forKey: .followIgnores) ?? []
        disabledPlugins = try container.decodeIfPresent([String].self, forKey: .disabledPlugins) ?? []
    }

    /// Matched against file names, so a directory reorganised around the same files keeps
    /// its switches.
    public func loadsPlugin(_ fileName: String) -> Bool {
        !disabledPlugins.contains(fileName)
    }

    /// The canvas, held to something the encoder accepts: 320 to 7680 points, and even
    /// numbers, which H.264 requires.
    public var canvasSize: CGSize {
        guard let output else { return OutputCanvas.standard }
        let clamp = { (value: Double) in (min(max(value, 320), 7680) / 2).rounded(.down) * 2 }
        return CGSize(width: clamp(output.width), height: clamp(output.height))
    }

    /// Matched case-insensitively against the app's name and its bundle id, so both
    /// `"Slack"` and `"com.tinyspeck.slackmacgap"` work and neither needs exact casing.
    public func ignoresFocus(app name: String?, bundleID: String?) -> Bool {
        let candidates = [name, bundleID].compactMap { $0?.lowercased() }
        return followIgnores.contains { candidates.contains($0.lowercased()) }
    }

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
            .map { preset in
                // A position takes both coordinates; half of one is no position at all.
                var origin: CGPoint?
                if let x = preset.x, let y = preset.y { origin = CGPoint(x: x, y: y) }
                return RegionSize(name: preset.name,
                                  size: CGSize(width: preset.width, height: preset.height),
                                  origin: origin)
            }
    }

    /// The commands the config binds a shortcut to, ignoring any arguments. A default
    /// shortcut for one of these stands down, so rebinding replaces rather than doubles.
    public var boundCommands: Set<String> {
        Set(hotkeys.values.map { String($0.prefix(while: { $0 != "?" })) })
    }
}
