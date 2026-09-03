import XCTest
@testable import VirtualDisplayCore

/// Plugins are arbitrary user code running in-process. The bar is that nothing a plugin
/// does, including being wrong, can take the app down or silently do nothing.
@MainActor
final class LuaRuntimeTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-plugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func plugin(_ name: String, _ source: String) {
        try? source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testAPluginDrivesTheAppThroughCommands() {
        plugin("a.lua", #"vd.command("set-size", { width = 1280, height = 720 })"#)

        var calls: [(String, [String: String])] = []
        var host = LuaRuntime.Host()
        host.perform = { name, args in calls.append((name, args)); return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(runtime.errors, [])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "set-size")
        // Numbers arrive as text, because that is what a command takes.
        XCTAssertEqual(calls.first?.1, ["width": "1280", "height": "720"])
    }

    func testABrokenPluginIsReportedAndTheOthersStillLoad() {
        plugin("10-broken.lua", "this is not lua")
        plugin("20-fine.lua", #"vd.command("toggle-pause")"#)

        var fired = false
        var host = LuaRuntime.Host()
        host.perform = { _, _ in fired = true; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(runtime.errors.count, 1)
        XCTAssertTrue(runtime.errors[0].contains("10-broken.lua"))
        XCTAssertTrue(fired, "a broken plugin must not stop the next one loading")
    }

    /// A Lua error at runtime is caught by pcall, not by crashing the process.
    func testAnErrorInsideAnEventHandlerIsContained() {
        plugin("a.lua", #"vd.on("mirroring", function(e) error("boom") end)"#)

        let runtime = LuaRuntime(host: LuaRuntime.Host())
        runtime.load(from: directory)
        XCTAssertEqual(runtime.errors, [])

        runtime.emit("mirroring", ["on": true])
        XCTAssertEqual(runtime.errors.count, 1)
        XCTAssertTrue(runtime.errors[0].contains("boom"))
    }

    func testEventsReachTheirHandlersWithTheirFields() {
        plugin("a.lua", """
        vd.on("mirroring", function(e)
            vd.command("noted", { on = tostring(e.on) })
        end)
        """)

        var seen: [String: String]?
        var host = LuaRuntime.Host()
        host.perform = { _, args in seen = args; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)
        runtime.emit("mirroring", ["on": true])

        XCTAssertEqual(seen, ["on": "true"])
    }

    /// New behaviour, reachable from the menu, a shortcut and the URL scheme alike.
    func testAPluginCanRegisterACommandThatRunsLua() throws {
        plugin("a.lua", """
        vd.register("double", function(args)
            return tostring(tonumber(args.n) * 2)
        end)
        """)

        let center = CommandCenter()
        var host = LuaRuntime.Host()
        host.registerCommand = { name, body in
            center.register(name, "plugin", owner: .plugin, run: body)
        }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        let result = try center.perform("double", CommandCenter.Arguments(["n": "21"]))
        XCTAssertEqual(result, "42")
        _ = runtime   // kept alive for the duration of the call
    }

    func testPresetsMenuItemsAndHotKeysReachTheApp() {
        plugin("a.lua", """
        vd.preset("Notes strip", 700, 1000)
        vd.menu("Do the thing", function() vd.command("thing") end)
        vd.hotkey("ctrl-opt-cmd-r", function() end)
        """)

        var presets: [RegionSize] = []
        var menuTitles: [String] = []
        var keys: [KeySpec] = []
        var menuRan = false

        var host = LuaRuntime.Host()
        host.addPreset = { presets.append($0) }
        host.addMenuItem = { title, run in menuTitles.append(title); run() }
        host.addHotKey = { spec, _ in keys.append(spec); return true }
        host.perform = { _, _ in menuRan = true; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(presets.first?.name, "Notes strip")
        XCTAssertEqual(presets.first?.size, CGSize(width: 700, height: 1000))
        XCTAssertEqual(menuTitles, ["Do the thing"])
        XCTAssertTrue(menuRan, "the menu item must call back into Lua")
        XCTAssertEqual(keys.first, KeySpec("ctrl-opt-cmd-r"))
    }

    /// A plugin asking for something that does not exist gets an answer, not an exception.
    func testFailuresComeBackAsNilAndAMessage() {
        plugin("a.lua", """
        local ok, err = vd.command("nope")
        vd.command("report", { ok = tostring(ok), err = err })
        """)

        var reported: [String: String]?
        var host = LuaRuntime.Host()
        host.perform = { name, args in
            if name == "report" { reported = args; return nil }
            throw CommandCenter.Failure.unknownCommand(name)
        }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(runtime.errors, [])
        XCTAssertEqual(reported?["ok"], "nil")
        XCTAssertEqual(reported?["err"], "unknown command \"nope\"")
    }

    func testStateAndWindowsAreReadableFromLua() {
        plugin("a.lua", """
        local s = vd.state()
        local w = vd.windows()[1]
        vd.command("report", {
            mirroring = tostring(s.isMirroring),
            app = w.app,
            width = tostring(w.w),
        })
        """)

        var reported: [String: String]?
        var state = AppState()
        state.isMirroring = true

        var host = LuaRuntime.Host()
        host.state = { state }
        host.windows = {
            [ScreenWindow(app: "Preview", title: "Doc", pid: 42,
                          frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        }
        host.perform = { _, args in reported = args; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(reported?["mirroring"], "true")
        XCTAssertEqual(reported?["app"], "Preview")
        XCTAssertEqual(reported?["width"], "800.0")
    }

    func testUnloadStopsEventsFromReachingAClosedState() {
        plugin("a.lua", #"vd.on("mirroring", function() vd.command("x") end)"#)

        var fired = 0
        var host = LuaRuntime.Host()
        host.perform = { _, _ in fired += 1; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)
        runtime.emit("mirroring")
        runtime.unload()
        runtime.emit("mirroring")

        XCTAssertEqual(fired, 1)
        XCTAssertFalse(runtime.isLoaded)
    }

    /// vd.overlay is sugar over the same command a URL would use, so both paths agree.
    func testOverlaySugarBecomesTheOverlayCommands() {
        plugin("a.lua", """
        vd.overlay("clock", { text = "12:00", x = 0.5, size = 40 })
        vd.overlay("clock", nil)
        vd.clear_overlays()
        """)

        var calls: [(String, [String: String])] = []
        var host = LuaRuntime.Host()
        host.perform = { name, args in calls.append((name, args)); return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(runtime.errors, [])
        XCTAssertEqual(calls.map(\.0), ["set-overlay", "clear-overlay", "clear-overlays"])
        XCTAssertEqual(calls[0].1, ["id": "clock", "text": "12:00", "x": "0.5", "size": "40"])
        XCTAssertEqual(calls[1].1, ["id": "clock"])
    }

    func testFetchPassesHeadersAndHandsBackTheBody() {
        plugin("a.lua", """
        vd.fetch("https://example.com/now", { headers = { Authorization = "Bearer x" } },
            function(res)
                vd.overlay("track", { text = res.body, alpha = res.ok and 1 or 0.5 })
            end)
        """)

        var requested: FetchRequest?
        var overlaid: [String: String]?
        var host = LuaRuntime.Host()
        host.fetch = { request, done in
            requested = request
            done("Miles Davis", 200, nil)   // synchronous stands in for the network
        }
        host.perform = { name, args in
            if name == "set-overlay" { overlaid = args }
            return nil
        }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(runtime.errors, [])
        XCTAssertEqual(requested?.url, "https://example.com/now")
        XCTAssertEqual(requested?.headers, ["Authorization": "Bearer x"])
        XCTAssertEqual(overlaid?["text"], "Miles Davis")
        XCTAssertEqual(overlaid?["alpha"], "1")
    }

    func testAFailedFetchReachesThePluginAsAMessage() {
        plugin("a.lua", """
        vd.fetch("https://example.com", function(res)
            vd.command("report", { ok = res.ok, status = res.status, err = res.error })
        end)
        """)

        var reported: [String: String]?
        var host = LuaRuntime.Host()
        host.fetch = { _, done in done(nil, 0, "offline") }
        host.perform = { _, args in reported = args; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertEqual(reported?["ok"], "false")
        XCTAssertEqual(reported?["status"], "0")
        XCTAssertEqual(reported?["err"], "offline")
    }

    /// A plugin inherits the app's Screen Recording grant, so a file anyone else can
    /// rewrite must never be loaded: that is how a process with no permissions of its own
    /// would get one.
    func testRefusesAPluginOtherUsersCanWrite() throws {
        plugin("a.lua", #"vd.command("ran")"#)
        let script = directory.appendingPathComponent("a.lua")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: script.path)

        var fired = false
        var host = LuaRuntime.Host()
        host.perform = { _, _ in fired = true; return nil }

        let runtime = LuaRuntime(host: host)
        runtime.load(from: directory)

        XCTAssertFalse(fired)
        XCTAssertEqual(runtime.errors.count, 1)
        XCTAssertTrue(runtime.errors[0].contains("writable by others"), runtime.errors[0])
        XCTAssertFalse(runtime.isLoaded)
    }

    func testAcceptsAnOrdinaryPrivateFile() throws {
        plugin("a.lua", #"vd.command("ran")"#)
        let script = directory.appendingPathComponent("a.lua")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        XCTAssertTrue(LuaRuntime.isSafelyOwned(script))
    }

    func testAnEmptyPluginDirectoryStartsNothing() {
        let runtime = LuaRuntime(host: LuaRuntime.Host())
        runtime.load(from: directory)
        XCTAssertFalse(runtime.isLoaded)
        XCTAssertEqual(runtime.errors, [])
    }
}
