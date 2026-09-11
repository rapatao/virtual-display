import Carbon.HIToolbox
import XCTest
@testable import VirtualDisplayCore

/// The settings window writes the same file people hand-edit, so a round trip has to come
/// back identical, and rebinding has to replace rather than accumulate.
@MainActor
final class SettingsModelTests: XCTestCase {

    private var url: URL!
    private var saved: [Config] = []

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-settings-\(UUID().uuidString).json")
        saved = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func model(_ config: Config = Config()) -> SettingsModel {
        var environment = SettingsWindow.Environment()
        environment.config = { config }
        environment.save = { [self] in saved.append($0) }
        environment.regionFrame = { CGRect(x: 100, y: 200, width: 1280, height: 720) }
        return SettingsModel(environment: environment)
    }

    func testSavingRoundTripsThroughTheFile() throws {
        var config = Config()
        config.presets = [Config.Preset(name: "Notes strip", width: 700, height: 1000)]
        config.hotkeys = ["ctrl-opt-cmd-b": "snap-to-window-below"]
        config.captures = Config.Captures(screenshots: "/tmp/shots", recordings: nil)

        try config.save(to: url)
        XCTAssertEqual(Config.load(from: url), config)
    }

    func testAddingTheCurrentRegionAsAPreset() {
        let model = model()
        model.addCurrentRegionAsPreset()
        XCTAssertEqual(model.config.presets.first?.name, "1280 x 720")
        XCTAssertEqual(model.config.presets.first?.width, 1280)
        XCTAssertEqual(saved.count, 1, "every edit writes the file; there is no Save button")
    }

    func testAddingABlankPresetGivesAUsableStartingPoint() {
        let model = model()
        model.addPreset()
        XCTAssertEqual(model.config.presets.first?.width, 1280)
        XCTAssertEqual(model.config.presets.first?.height, 720)
        // A row left untouched must still be a preset the menu can apply.
        XCTAssertEqual(model.config.regionSizes.count, 1)
    }

    /// Typing a name empties the field for a moment, and a width starts at nothing. Those
    /// rows must not reach the menu, and must not be deleted either.
    func testHalfTypedPresetsStayInTheFileButOutOfTheMenu() {
        var config = Config()
        config.presets = [Config.Preset(name: "", width: 0, height: 0),
                          Config.Preset(name: "Notes", width: 700, height: 1000)]
        let model = model(config)
        XCTAssertEqual(model.config.presets.count, 2)
        XCTAssertEqual(model.config.regionSizes.map(\.name), ["Notes"])
    }

    /// Binding a second shortcut to an action must move it, not leave two live.
    func testRebindingReplacesThePreviousShortcut() {
        let model = model()
        model.bind("ctrl-opt-cmd-1", to: "screenshot")
        model.bind("cmd-shift-f5", to: "screenshot")
        XCTAssertEqual(model.config.hotkeys, ["cmd-shift-f5": "screenshot"])
    }

    func testUnbindingRemovesIt() {
        var config = Config()
        config.hotkeys = ["ctrl-opt-cmd-s": "screenshot"]
        let model = model(config)
        model.unbind("ctrl-opt-cmd-s")
        XCTAssertTrue(model.config.hotkeys.isEmpty)
    }

    /// The list is matched whole and case-insensitively, so a second spelling of an app
    /// already on it is noise, not a new rule.
    func testFollowIgnoresAreAddedOnceAndRemovable() {
        let model = model()
        model.addFollowIgnore("Slack")
        model.addFollowIgnore("slack")
        model.addFollowIgnore("  ")
        XCTAssertEqual(model.config.followIgnores, ["Slack"])

        model.addFollowIgnore("zoom.us")
        model.removeFollowIgnores(IndexSet(integer: 0))
        XCTAssertEqual(model.config.followIgnores, ["zoom.us"])
        XCTAssertEqual(saved.count, 3, "every edit writes the file; there is no Save button")
    }

    /// The switch beside each plugin. Turning one off must not disturb the others, and
    /// turning it back on must leave nothing behind in the file.
    func testPluginsAreDisabledAndEnabledOneAtATime() {
        let model = model()
        XCTAssertTrue(model.isPluginEnabled("10-clock.lua"))

        model.setPluginEnabled("10-clock.lua", false)
        model.setPluginEnabled("10-clock.lua", false)   // no duplicate row in the file
        XCTAssertEqual(model.config.disabledPlugins, ["10-clock.lua"])
        XCTAssertFalse(model.isPluginEnabled("10-clock.lua"))
        XCTAssertTrue(model.isPluginEnabled("20-ticker.lua"))

        model.setPluginEnabled("20-ticker.lua", false)
        model.setPluginEnabled("10-clock.lua", true)
        XCTAssertEqual(model.config.disabledPlugins, ["20-ticker.lua"])
    }

    func testCaptureFoldersAreSetAndCleared() {
        let model = model()
        model.setFolder("/tmp/shots", screenshots: true)
        model.setFolder("/tmp/movies", screenshots: false)
        XCTAssertEqual(model.config.captures?.screenshots, "/tmp/shots")
        XCTAssertEqual(model.config.captures?.recordings, "/tmp/movies")
        model.setFolder(nil, screenshots: true)
        XCTAssertNil(model.config.captures?.screenshots)
        XCTAssertEqual(model.config.captures?.recordings, "/tmp/movies", "one folder, not both")
    }
}

/// Recording a shortcut suspends the hot keys, saves the config, and resumes. The save
/// re-registers everything in between, which is what used to leave two live Carbon
/// registrations on one combination and fire the action twice per press.
@MainActor
final class HotKeySuspensionTests: XCTestCase {

    /// Nothing else in this process registers a shortcut, so both owners are ours to
    /// hand back.
    override func tearDown() {
        HotKeyCenter.shared.setSuspended(false)
        HotKeyCenter.shared.unregister(owner: .plugin)
        HotKeyCenter.shared.unregister(owner: .app)
        super.tearDown()
    }

    func testABindingMadeWhileSuspendedIsRegisteredExactlyOnce() {
        let center = HotKeyCenter.shared
        center.setSuspended(true)
        let before = center.registrationAttempts
        // What `adopt()` does behind an open recorder: drop the old binding, add the new.
        center.unregister(owner: .plugin)
        XCTAssertTrue(center.register(keyCode: 15, owner: .plugin, label: "test-r") {})
        center.setSuspended(false)

        // Twice was the bug: once while suspended, once on resume, with only the second
        // ref kept. Both stayed live and the combination fired the action twice.
        XCTAssertEqual(center.registrationAttempts - before, 1)
        let mine = center.summary().filter { $0.hasPrefix("test-r:") }
        XCTAssertEqual(mine.count, 1, "one binding, one line: \(center.summary())")
    }

    /// The app re-registers its shortcuts on every config save, so a key another app holds
    /// used to add a duplicate refusal line per keystroke typed in the settings window.
    func testRefusalsDoNotAccumulateAcrossReRegistration() {
        let center = HotKeyCenter.shared
        // Three saves in the settings window, which is three characters typed.
        for _ in 0..<3 {
            center.unregister(owner: .app)
            // The same combination twice: whatever the environment makes of the first,
            // the second is a duplicate and is refused.
            center.register(keyCode: 15, owner: .app, label: "test-r") {}
            center.register(keyCode: 15, owner: .app, label: "test-r") {}
        }
        let taken = center.summary().filter { $0.hasPrefix("test-r:") && $0.contains("TAKEN") }
        XCTAssertEqual(taken.count, 1, "one refusal, not one per save: \(taken)")
    }
}

final class ShortcutRoundTripTests: XCTestCase {

    /// The recorder writes specs back into the file the parser reads.
    func testEverySpecSurvivesBeingWrittenAndParsedAgain() throws {
        for text in ["ctrl-opt-cmd-r", "cmd-shift-f5", "ctrl-cmd-left", "opt-cmd-.", "shift-cmd-9"] {
            let parsed = try XCTUnwrap(KeySpec(text), text)
            let spec = try XCTUnwrap(parsed.spec, text)
            XCTAssertEqual(KeySpec(spec), parsed, "\(text) -> \(spec)")
        }
    }

    func testSpecUsesAFixedModifierOrder() {
        let spec = KeySpec(keyCode: 15, modifiers: UInt32(cmdKey | controlKey | optionKey)).spec
        XCTAssertEqual(spec, "ctrl-opt-cmd-r")
    }
}

/// What the menu shows for a shortcut. A wrong mapping here is a menu item that either
/// displays nothing or claims the wrong keys.
final class MenuShortcutTests: XCTestCase {

    func testLettersAndDigitsMapToTheirCharacter() throws {
        let spec = try XCTUnwrap(KeySpec("ctrl-opt-cmd-s"))
        XCTAssertEqual(spec.menuKey, "s")
        XCTAssertEqual(spec.menuModifiers, [.control, .option, .command])
    }

    func testFunctionKeysAndArrowsUseAppKitsPrivateCharacters() throws {
        let f5 = try XCTUnwrap(KeySpec("cmd-shift-f5"))
        XCTAssertEqual(f5.menuKey.unicodeScalars.first?.value, UInt32(NSF5FunctionKey))
        XCTAssertEqual(f5.menuModifiers, [.command, .shift])

        let left = try XCTUnwrap(KeySpec("ctrl-cmd-left"))
        XCTAssertEqual(left.menuKey.unicodeScalars.first?.value, UInt32(NSLeftArrowFunctionKey))
    }

    func testPunctuationStillShows() throws {
        XCTAssertEqual(try XCTUnwrap(KeySpec("opt-cmd-.")).menuKey, ".")
    }
}

final class CaptureFolderTests: XCTestCase {

    /// A folder chosen in settings is used, and cleared means back to ~/Pictures.
    func testChosenFolderOverridesTheSystemOne() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-captures-\(UUID().uuidString)")
        addTeardownBlock {
            CaptureFiles.screenshotFolder = nil
            try? FileManager.default.removeItem(at: folder)
        }

        CaptureFiles.screenshotFolder = folder.path
        let chosen = try CaptureFiles.screenshot()
        XCTAssertEqual(chosen.deletingLastPathComponent().path, folder.path)
        // Created up front, so the capture cannot fail for want of the folder.
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        CaptureFiles.screenshotFolder = nil
        XCTAssertTrue(try CaptureFiles.screenshot().path.contains("/Pictures/"))
    }
}
