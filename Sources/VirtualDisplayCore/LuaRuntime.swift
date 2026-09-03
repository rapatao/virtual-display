import AppKit
import CLua

/// Runs the Lua plugins in `~/.config/virtual-display/plugins/*.lua`.
///
/// One `lua_State`, main thread only, one global table `vd`. Everything a plugin can do it
/// does through `CommandCenter`, so a plugin has exactly the vocabulary the menu and the
/// URL scheme have, plus the events and timers that let it act on its own.
///
/// Errors never propagate as Lua errors across a Swift frame: `lua_error` unwinds with
/// `longjmp`, which would skip Swift's cleanup. Every `vd` call returns `nil, message`
/// instead, the way Lua's own `io` library does.
@MainActor
public final class LuaRuntime {

    /// What the runtime is allowed to do to the app. Closures rather than a reference to
    /// the coordinator, so the API can be exercised in tests without an app.
    public struct Host {
        public var perform: (String, [String: String]) throws -> String? = { _, _ in nil }
        public var registerCommand: (String, @escaping (CommandCenter.Arguments) throws -> String?) -> Void = { _, _ in }
        public var addPreset: (RegionSize) -> Void = { _ in }
        public var addMenuItem: (String, @escaping () -> Void) -> Void = { _, _ in }
        public var addHotKey: (KeySpec, @escaping () -> Void) -> Bool = { _, _ in false }
        public var state: () -> AppState = { AppState() }
        public var region: () -> CGRect = { .zero }
        public var windows: () -> [ScreenWindow] = { [] }
        /// Outbound HTTP, only ever because a plugin asked for it.
        public var fetch: (FetchRequest, @escaping (String?, Int, String?) -> Void) -> Void = {
            _, done in done(nil, 0, "fetch is unavailable")
        }
        public init() {}
    }

    private let host: Host
    private var lua: OpaquePointer?
    /// The Swift side of every `vd` function, addressed by the index carried as an upvalue.
    private var functions: [(OpaquePointer) -> Int32] = []
    private var eventHandlers: [String: [Int32]] = [:]
    /// Bumped on every unload, so a timer scheduled by a plugin that has since been
    /// reloaded fires into nothing instead of into a closed state.
    private var generation = 0

    /// What went wrong, for the menu to show. Empty is the normal case.
    public private(set) var errors: [String] = []

    public init(host: Host) {
        self.host = host
    }

    deinit {
        // Not `unload()`: deinit is nonisolated, and closing the state is all that is left.
        if let lua { lua_close(lua) }
    }

    // MARK: Loading

    public func load(from directory: URL = ConfigPaths.plugins) {
        unload()
        errors = []

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        // Sorted, so a plugin can rely on 10-base.lua running before 20-extra.lua.
        let candidates = files.filter { $0.pathExtension == "lua" }.sorted { $0.path < $1.path }
        let scripts = candidates.filter { script in
            guard Self.isSafelyOwned(script) else {
                record("\(script.lastPathComponent): skipped, not owned by you or writable by others")
                return false
            }
            return true
        }
        guard !scripts.isEmpty else { return }

        guard let state = luaL_newstate() else {
            record("could not start Lua")
            return
        }
        lua = state
        luaL_openlibs(state)
        restrictNativeLoading(state, pluginsDirectory: directory)
        installAPI(state)
        installPrelude(state)

        for script in scripts {
            // Each script is independent: one that fails must not take the others with it.
            if luaL_loadfilex(state, script.path, nil) != luaOK
                || lua_pcallk(state, 0, 0, 0, 0, nil) != luaOK {
                record("\(script.lastPathComponent): \(popMessage(state))")
            }
        }
    }

    /// A plugin is code, so the file has to be as trustworthy as the decision to run it:
    /// owned by whoever is running the app, and not writable by anyone else. This is what
    /// stops a plugin dropped by some other process from inheriting Screen Recording.
    static func isSafelyOwned(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }

        guard owner.uint32Value == getuid() else { return false }
        return permissions.uint16Value & 0o022 == 0   // not group- or world-writable
    }

    public func unload() {
        if let lua { lua_close(lua) }
        lua = nil
        functions = []
        eventHandlers = [:]
        generation += 1
    }

    public var isLoaded: Bool { lua != nil }

    /// Native module loading is pointless here and confusing when it fails: the hardened
    /// runtime blocks unsigned `.so` loading anyway. Plain Lua `require` still works, out
    /// of the plugins directory.
    private func restrictNativeLoading(_ state: OpaquePointer, pluginsDirectory: URL) {
        let directory = pluginsDirectory.path
        run(state, """
            package.loadlib = nil
            package.cpath = ""
            for i = #package.searchers, 3, -1 do package.searchers[i] = nil end
            package.path = [==[\(directory)/?.lua;\(directory)/?/init.lua]==]
            """)
    }

    private func run(_ state: OpaquePointer, _ chunk: String) {
        if loadString(state, chunk) != luaOK || lua_pcallk(state, 0, 0, 0, 0, nil) != luaOK {
            record(popMessage(state))
        }
    }

    private func record(_ message: String) {
        errors.append(message)
        NSLog("virtual-display: plugin: %@", message)
    }

    // MARK: Events

    /// Called by the app when something happened. Unknown events cost nothing.
    public func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard let state = lua, let handlers = eventHandlers[event] else { return }
        for ref in handlers {
            lua_rawgeti(state, luaRegistryIndex, lua_Integer(ref))
            push(state, fields)
            if lua_pcallk(state, 1, 0, 0, 0, nil) != luaOK {
                record("\(event): \(popMessage(state))")
            }
        }
    }

    /// Calls a stored Lua function with a string table, returning its result as text.
    @discardableResult
    private func call(ref: Int32, with arguments: [String: String] = [:]) -> String? {
        guard let state = lua else { return nil }
        lua_rawgeti(state, luaRegistryIndex, lua_Integer(ref))
        push(state, arguments)
        guard lua_pcallk(state, 1, 1, 0, 0, nil) == luaOK else {
            record(popMessage(state))
            return nil
        }
        let result = text(state, -1)
        pop(state, 1)
        return result
    }

    // MARK: The vd table

    private func installAPI(_ state: OpaquePointer) {
        lua_createtable(state, 0, 12)

        define(state, "log") { [weak self] s in
            NSLog("virtual-display: plugin: %@", self?.text(s, 1) ?? "")
            return 0
        }

        define(state, "command") { [weak self] s in
            guard let self else { return 0 }
            guard let name = text(s, 1) else { return fail(s, "vd.command needs a command name") }
            do {
                let result = try host.perform(name, table(s, 2))
                if let result { lua_pushstring(s, result) } else { lua_pushboolean(s, 1) }
                return 1
            } catch {
                return fail(s, error.localizedDescription)
            }
        }

        define(state, "register") { [weak self] s in
            guard let self else { return 0 }
            guard let name = text(s, 1) else { return fail(s, "vd.register needs a name") }
            guard let ref = reference(s, 2) else { return fail(s, "vd.register needs a function") }
            host.registerCommand(name) { [weak self] arguments in
                self?.call(ref: ref, with: arguments.all) ?? nil
            }
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "on") { [weak self] s in
            guard let self else { return 0 }
            guard let event = text(s, 1) else { return fail(s, "vd.on needs an event name") }
            guard let ref = reference(s, 2) else { return fail(s, "vd.on needs a function") }
            eventHandlers[event, default: []].append(ref)
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "hotkey") { [weak self] s in
            guard let self else { return 0 }
            guard let spec = text(s, 1).flatMap(KeySpec.init) else {
                return fail(s, "vd.hotkey needs a shortcut like \"ctrl-opt-cmd-r\"")
            }
            guard let ref = reference(s, 2) else { return fail(s, "vd.hotkey needs a function") }
            guard host.addHotKey(spec, { [weak self] in self?.call(ref: ref) }) else {
                return fail(s, "that shortcut is already taken")
            }
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "preset") { [weak self] s in
            guard let self else { return 0 }
            guard let name = text(s, 1) else { return fail(s, "vd.preset needs a name") }
            let size = CGSize(width: lua_tonumberx(s, 2, nil), height: lua_tonumberx(s, 3, nil))
            guard size.width > 0, size.height > 0 else {
                return fail(s, "vd.preset needs a width and a height")
            }
            host.addPreset(RegionSize(name: name, size: size))
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "menu") { [weak self] s in
            guard let self else { return 0 }
            guard let title = text(s, 1) else { return fail(s, "vd.menu needs a title") }
            guard let ref = reference(s, 2) else { return fail(s, "vd.menu needs a function") }
            host.addMenuItem(title) { [weak self] in self?.call(ref: ref) }
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "timer") { [weak self] s in
            guard let self else { return 0 }
            let seconds = lua_tonumberx(s, 1, nil)
            guard seconds >= 0 else { return fail(s, "vd.timer needs a delay in seconds") }
            guard let ref = reference(s, 2) else { return fail(s, "vd.timer needs a function") }
            let scheduled = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, generation == scheduled else { return }   // reloaded since
                call(ref: ref)
                release(ref)   // one-shot: a repeating timer re-arms and takes a new slot
            }
            lua_pushboolean(s, 1)
            return 1
        }

        // vd.fetch(url, callback) or vd.fetch(url, options, callback). The prelude below
        // flattens a nested `headers` table into what this takes.
        define(state, "fetch") { [weak self] s in
            guard let self else { return 0 }
            guard let url = text(s, 1) else { return fail(s, "vd.fetch needs a url") }
            let hasOptions = lua_type(s, 2) == luaTypeTable
            guard let ref = reference(s, hasOptions ? 3 : 2) else {
                return fail(s, "vd.fetch needs a function to call back")
            }
            let request = FetchRequest(url: url, options: hasOptions ? table(s, 2) : [:])
            let scheduled = generation
            host.fetch(request) { [weak self] body, status, error in
                guard let self, generation == scheduled else { return }   // reloaded since
                let ok = error == nil && (200..<300).contains(status)
                call(ref: ref, with: ["body": body ?? "",
                                      "status": String(status),
                                      "ok": ok ? "true" : "false",
                                      "error": error ?? ""])
                release(ref)
            }
            lua_pushboolean(s, 1)
            return 1
        }

        define(state, "state") { [weak self] s in
            guard let self else { return 0 }
            let state = host.state()
            push(s, [
                "hasScreenRecordingAccess": state.hasScreenRecordingAccess,
                "isMirroring": state.isMirroring,
                "isPaused": state.isPaused,
                "isCapturing": state.isCapturing,
                "isEditingRegion": state.isEditingRegion,
                "showsCursor": state.showsCursor,
                "isLoginItemEnabled": state.isLoginItemEnabled,
                "isRecording": state.isRecording,
            ])
            return 1
        }

        define(state, "region") { [weak self] s in
            guard let self else { return 0 }
            let frame = host.region()
            push(s, ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height])
            return 1
        }

        define(state, "windows") { [weak self] s in
            guard let self else { return 0 }
            let windows = host.windows()
            lua_createtable(s, Int32(windows.count), 0)
            for (index, window) in windows.enumerated() {
                push(s, ["app": window.app, "title": window.title, "pid": Double(window.pid),
                         "x": window.frame.minX, "y": window.frame.minY,
                         "w": window.frame.width, "h": window.frame.height])
                lua_rawseti(s, -2, lua_Integer(index + 1))
            }
            return 1
        }

        lua_setglobal(state, "vd")
    }

    /// The parts of the API that are easier written in Lua than bridged: `vd.overlay` is
    /// sugar over the `set-overlay` command, so an overlay behaves identically whether it
    /// comes from a plugin, the menu or a `virtualdisplay://` URL.
    private func installPrelude(_ state: OpaquePointer) {
        run(state, """
            function vd.overlay(id, spec)
                if spec == nil then return vd.command("clear-overlay", { id = id }) end
                local args = { id = id }
                for key, value in pairs(spec) do args[key] = value end
                return vd.command("set-overlay", args)
            end

            function vd.clear_overlays()
                return vd.command("clear-overlays")
            end

            local send = vd.fetch
            function vd.fetch(url, options, callback)
                if type(options) == "function" then return send(url, options) end
                local flat = {}
                for key, value in pairs(options or {}) do
                    if key == "headers" then
                        for name, header in pairs(value) do flat["header." .. name] = header end
                    else
                        flat[key] = value
                    end
                end
                return send(url, flat, callback)
            end
            """)
    }

    /// Swift closures cannot be C function pointers, so every `vd` function is the same
    /// trampoline carrying an index into `functions` as an upvalue.
    private func define(_ state: OpaquePointer,
                        _ name: String,
                        _ body: @escaping (OpaquePointer) -> Int32) {
        functions.append(body)
        lua_pushlightuserdata(state, Unmanaged.passUnretained(self).toOpaque())
        lua_pushinteger(state, lua_Integer(functions.count - 1))
        lua_pushcclosure(state, luaTrampoline, 2)
        lua_setfield(state, -2, name)
    }

    fileprivate func invoke(_ index: Int, _ state: OpaquePointer) -> Int32 {
        guard functions.indices.contains(index) else { return 0 }
        return functions[index](state)
    }

    // MARK: Stack helpers

    /// A failure is two return values, `nil` and a message, never a Lua error: raising one
    /// from here would `longjmp` straight past Swift's cleanup.
    private func fail(_ state: OpaquePointer, _ message: String) -> Int32 {
        lua_pushnil(state)
        lua_pushstring(state, message)
        return 2
    }

    private func popMessage(_ state: OpaquePointer) -> String {
        let message = text(state, -1) ?? "unknown error"
        pop(state, 1)
        return message
    }

    /// Strings, numbers and booleans all arrive as text, because that is what a command
    /// takes. Anything else is not convertible and reads as absent.
    private func text(_ state: OpaquePointer, _ index: Int32) -> String? {
        switch lua_type(state, index) {
        case luaTypeBoolean:
            return lua_toboolean(state, index) != 0 ? "true" : "false"
        case luaTypeString, luaTypeNumber:
            // On a copy: lua_tolstring rewrites a number in place, which would break the
            // lua_next walk in `table` if the value were a key.
            lua_pushvalue(state, index)
            defer { pop(state, 1) }
            guard let c = lua_tolstring(state, -1, nil) else { return nil }
            return String(cString: c)
        default:
            return nil
        }
    }

    /// A Lua table of arguments as the string pairs a command takes.
    private func table(_ state: OpaquePointer, _ index: Int32) -> [String: String] {
        guard lua_type(state, index) == luaTypeTable else { return [:] }
        var pairs: [String: String] = [:]
        lua_pushnil(state)
        while lua_next(state, index) != 0 {
            if lua_type(state, -2) == luaTypeString,
               let key = text(state, -2), let value = text(state, -1) {
                pairs[key] = value
            }
            pop(state, 1)   // the value; the key stays for the next step
        }
        return pairs
    }

    private func push(_ state: OpaquePointer, _ fields: [String: Any]) {
        lua_createtable(state, 0, Int32(fields.count))
        for (key, value) in fields {
            switch value {
            case let bool as Bool: lua_pushboolean(state, bool ? 1 : 0)
            case let number as Double: lua_pushnumber(state, number)
            case let number as CGFloat: lua_pushnumber(state, Double(number))
            case let number as Int: lua_pushinteger(state, lua_Integer(number))
            case let string as String: lua_pushstring(state, string)
            default: lua_pushnil(state)
            }
            lua_setfield(state, -2, key)
        }
    }

    /// Stores the function at `index` in the registry and returns its reference, so it can
    /// be called long after the call that registered it has returned.
    private func reference(_ state: OpaquePointer, _ index: Int32) -> Int32? {
        guard lua_type(state, index) == luaTypeFunction else { return nil }
        lua_pushvalue(state, index)
        return luaL_ref(state, luaRegistryIndex)
    }

    /// Gives a one-shot callback's registry slot back, so a plugin polling an API every
    /// second does not grow the registry all day.
    private func release(_ ref: Int32) {
        guard let lua else { return }
        luaL_unref(lua, luaRegistryIndex, ref)
    }

    private func pop(_ state: OpaquePointer, _ count: Int32) {
        lua_settop(state, -count - 1)
    }
}

/// Lua calls this for every `vd` function; the upvalues say which runtime and which one.
/// Lua only ever runs on the main thread here, which is what makes the hop safe.
private func luaTrampoline(_ state: OpaquePointer?) -> Int32 {
    guard let state,
          let raw = lua_touserdata(state, upvalueIndex(1))
    else { return 0 }
    let index = Int(lua_tointegerx(state, upvalueIndex(2), nil))
    let runtime = Unmanaged<LuaRuntime>.fromOpaque(raw).takeUnretainedValue()
    return MainActor.assumeIsolated { runtime.invoke(index, state) }
}

// Lua exposes these as C macros, which do not reach Swift.
private let luaRegistryIndex: Int32 = -1_001_000   // -LUAI_MAXSTACK - 1000
private func upvalueIndex(_ i: Int32) -> Int32 { luaRegistryIndex - i }
private let luaOK: Int32 = 0
private let luaTypeBoolean: Int32 = 1
private let luaTypeNumber: Int32 = 3
private let luaTypeString: Int32 = 4
private let luaTypeTable: Int32 = 5
private let luaTypeFunction: Int32 = 6

private func loadString(_ state: OpaquePointer, _ chunk: String) -> Int32 {
    chunk.withCString { luaL_loadbufferx(state, $0, strlen($0), $0, nil) }
}
