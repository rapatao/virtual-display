import XCTest
@testable import VirtualDisplayCore

/// The dispatch table every surface goes through: menu, hot keys, URL scheme, plugins.
/// A bug here breaks all four at once, which is exactly why it is worth pinning down.
@MainActor
final class CommandCenterTests: XCTestCase {

    func testPerformsARegisteredCommand() throws {
        let center = CommandCenter()
        var fired = 0
        center.register("go", "test", action: { fired += 1 })
        try center.perform("go")
        XCTAssertEqual(fired, 1)
    }

    func testUnknownCommandThrowsInsteadOfSilentlyDoingNothing() {
        let center = CommandCenter()
        XCTAssertThrowsError(try center.perform("nope"))
    }

    func testParsesArgumentsFromAURL() throws {
        let center = CommandCenter()
        var seen: CGSize?
        center.register("set-size", "test") { args in
            seen = CGSize(width: try args.double("width"), height: try args.double("height"))
            return nil
        }
        try center.perform(url: URL(string: "virtualdisplay://set-size?width=1280&height=720")!)
        XCTAssertEqual(seen, CGSize(width: 1280, height: 720))
    }

    /// Some URL builders produce the triple-slash form; both name the same command.
    func testAcceptsTheEmptyHostForm() throws {
        let center = CommandCenter()
        var fired = false
        center.register("toggle-mirroring", "test", action: { fired = true })
        try center.perform(url: URL(string: "virtualdisplay:///toggle-mirroring")!)
        XCTAssertTrue(fired)
    }

    func testBooleanArgumentsAcceptWhatEachCallerNaturallySends() throws {
        let center = CommandCenter()
        var seen: [Bool] = []
        center.register("set", "test") { args in seen.append(try args.bool("on")); return nil }
        for text in ["true", "1", "yes", "ON"] {
            try center.perform("set", CommandCenter.Arguments(["on": text]))
        }
        for text in ["false", "0", "no", "Off"] {
            try center.perform("set", CommandCenter.Arguments(["on": text]))
        }
        XCTAssertEqual(seen, [true, true, true, true, false, false, false, false])
    }

    func testBadArgumentsThrowRatherThanDefaultingToZero() {
        let center = CommandCenter()
        center.register("set", "test") { args in _ = try args.double("width"); return nil }
        XCTAssertThrowsError(try center.perform("set", CommandCenter.Arguments(["width": "wide"])))
        XCTAssertThrowsError(try center.perform("set"))   // missing entirely
    }

    /// Reloading plugins must drop what plugins added and keep what the app added.
    func testRemovingPluginCommandsLeavesTheAppsOwn() throws {
        let center = CommandCenter()
        center.register("app", "test", action: {})
        center.register("plugin", "test", owner: .plugin, action: {})
        center.removeAll(owner: .plugin)
        XCTAssertEqual(center.names, ["app"])
    }
}
