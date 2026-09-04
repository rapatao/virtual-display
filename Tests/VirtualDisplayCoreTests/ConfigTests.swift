import XCTest
@testable import VirtualDisplayCore

/// Shortcut specs come from a hand-edited file, so parsing them wrong means either a dead
/// shortcut or one bound to the wrong key.
final class KeySpecTests: XCTestCase {

    func testParsesModifiersAndKey() throws {
        let spec = try XCTUnwrap(KeySpec("ctrl-opt-cmd-r"))
        XCTAssertEqual(spec.keyCode, 15)   // kVK_ANSI_R
        XCTAssertEqual(spec.modifiers, HotKeyCenter.defaultModifiers)
    }

    func testAcceptsBothSeparatorsAndAnyCase() {
        XCTAssertEqual(KeySpec("Cmd+Shift+F5"), KeySpec("cmd-shift-f5"))
    }

    func testAcceptsModifierAliases() {
        XCTAssertEqual(KeySpec("alt-a"), KeySpec("option-a"))
        XCTAssertEqual(KeySpec("control-a"), KeySpec("ctrl-a"))
    }

    /// "ctrl-cmd--" binds the hyphen key; splitting naively would drop it.
    func testTrailingSeparatorIsTheKeyItself() throws {
        let spec = try XCTUnwrap(KeySpec("ctrl-cmd--"))
        XCTAssertEqual(spec.keyCode, 27)   // kVK_ANSI_Minus
    }

    func testUnknownNamesFailInsteadOfBindingSomethingElse() {
        XCTAssertNil(KeySpec("ctrl-hyper-r"))
        XCTAssertNil(KeySpec("cmd-nosuchkey"))
        XCTAssertNil(KeySpec(""))
    }
}

/// The config file is hand-edited too, and a menu bar app that will not launch because of
/// a stray comma leaves the user nothing to fix it with.
final class ConfigTests: XCTestCase {

    private func write(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-config-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsPresetsHotkeysAndDefaults() throws {
        let url = try write("""
        {
          "presets": [{ "name": "Notes strip", "width": 700, "height": 1000 }],
          "hotkeys": { "ctrl-opt-cmd-r": "snap-to-window-below" },
          "defaults": { "showsCursor": false }
        }
        """)
        let config = Config.load(from: url)
        XCTAssertEqual(config.presets.first?.name, "Notes strip")
        XCTAssertEqual(config.hotkeys["ctrl-opt-cmd-r"], "snap-to-window-below")
        XCTAssertEqual(config.defaults?.showsCursor, false)
        XCTAssertEqual(config.regionSizes.first?.size, CGSize(width: 700, height: 1000))
    }

    /// The list is typed by hand, so it matches on either the name or the bundle id and
    /// does not care about casing; getting this wrong puts an app on the call.
    func testFollowIgnoresMatchNameOrBundleIDInAnyCase() throws {
        let url = try write("""
        { "followIgnores": ["slack", "com.1password.1password"] }
        """)
        let config = Config.load(from: url)
        XCTAssertTrue(config.ignoresFocus(app: "Slack", bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(config.ignoresFocus(app: "1Password", bundleID: "com.1password.1Password"))
        XCTAssertFalse(config.ignoresFocus(app: "Safari", bundleID: "com.apple.Safari"))
        // A partial name is not a match: "Sla" must not silently cover Slack.
        XCTAssertFalse(config.ignoresFocus(app: "Slack Helper", bundleID: nil))
        XCTAssertFalse(Config().ignoresFocus(app: "Slack", bundleID: nil))
    }

    func testMissingFileIsTheNormalCase() {
        let missing = URL(fileURLWithPath: "/nonexistent/virtual-display/config.json")
        XCTAssertEqual(Config.load(from: missing), Config())
    }

    func testMalformedFileIsIgnoredRatherThanFatal() throws {
        let url = try write("{ \"presets\": [ oops }")
        XCTAssertEqual(Config.load(from: url), Config())
    }

    func testPartialFileKeepsTheRestAtItsDefault() throws {
        let url = try write("{ \"hotkeys\": { \"cmd-f1\": \"toggle-pause\" } }")
        let config = Config.load(from: url)
        // The key that IS there must survive: a missing "presets" used to discard the
        // whole file, which is how a new key would silently drop everyone's shortcuts.
        XCTAssertEqual(config.hotkeys["cmd-f1"], "toggle-pause")
        XCTAssertTrue(config.presets.isEmpty)
        XCTAssertTrue(config.followIgnores.isEmpty)
        XCTAssertNil(config.defaults)
    }
}

/// Preset lookup by name is what `set-size?name=` and every plugin calling it depend on.
final class RegionSizeMatchTests: XCTestCase {

    func testMatchesOnAPrefixSoTheMenuTitleNeedNotBeTyped() {
        let preset = RegionSize(name: "960 x 540  (1:1 on Retina)", size: CGSize(width: 960, height: 540))
        XCTAssertTrue(preset.matches("960"))
        XCTAssertTrue(preset.matches("960 x 540"))
        XCTAssertFalse(preset.matches("1280"))
    }

    func testSpotNamesRoundTrip() {
        for spot in RegionSpot.allCases {
            XCTAssertEqual(RegionSpot(commandName: spot.commandName), spot)
        }
        XCTAssertEqual(RegionSpot(commandName: "TOP-LEFT"), .topLeft)
        XCTAssertNil(RegionSpot(commandName: "middle"))
    }
}
