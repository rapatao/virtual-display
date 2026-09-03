import Foundation

/// Who registered a command or a shortcut. Reloading plugins drops everything they added
/// and leaves the app's own registrations alone.
public enum Owner: Sendable {
    case app
    case plugin
}

/// Every user-visible action, by name, in one table.
///
/// The menu, the global hot keys, the `virtualdisplay://` URL scheme and Lua plugins all
/// dispatch through here, so a behaviour is defined once and reachable from all four
/// instead of being re-wired per surface.
@MainActor
public final class CommandCenter {

    public struct Command {
        public let summary: String
        public let owner: Owner
        public let run: (Arguments) throws -> String?
    }

    /// Arguments are strings because a URL query is the lowest common denominator between
    /// the callers; Lua and the config file convert into the same shape.
    public struct Arguments {
        private let raw: [String: String]

        public init(_ raw: [String: String] = [:]) { self.raw = raw }

        public subscript(key: String) -> String? { raw[key] }
        public var isEmpty: Bool { raw.isEmpty }
        /// For handing a whole call on to something that speaks pairs, such as a plugin.
        public var all: [String: String] { raw }

        public func string(_ key: String) throws -> String {
            guard let value = raw[key] else { throw Failure.missingArgument(key) }
            return value
        }

        public func double(_ key: String) throws -> Double {
            let text = try string(key)
            guard let value = Double(text) else {
                throw Failure.badArgument(key, "expected a number, got \"\(text)\"")
            }
            return value
        }

        /// Accepts what each caller naturally produces: `?on=true` from a URL, `true` from
        /// Lua, `1` from a shell script.
        public func bool(_ key: String) throws -> Bool {
            let text = try string(key).lowercased()
            switch text {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw Failure.badArgument(key, "expected a boolean, got \"\(text)\"")
            }
        }
    }

    public enum Failure: LocalizedError {
        case unknownCommand(String)
        case missingArgument(String)
        case badArgument(String, String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unknownCommand(let name): return "unknown command \"\(name)\""
            case .missingArgument(let key): return "missing argument \"\(key)\""
            case .badArgument(let key, let why): return "bad argument \"\(key)\": \(why)"
            case .failed(let why): return why
            }
        }
    }

    private var commands: [String: Command] = [:]

    public init() {}

    public func register(_ name: String,
                         _ summary: String,
                         owner: Owner = .app,
                         run: @escaping (Arguments) throws -> String?) {
        commands[name] = Command(summary: summary, owner: owner, run: run)
    }

    /// Convenience for the many commands that take nothing and return nothing.
    public func register(_ name: String, _ summary: String, owner: Owner = .app,
                         action: @escaping () -> Void) {
        register(name, summary, owner: owner) { _ in action(); return nil }
    }

    @discardableResult
    public func perform(_ name: String, _ arguments: Arguments = Arguments()) throws -> String? {
        guard let command = commands[name] else { throw Failure.unknownCommand(name) }
        return try command.run(arguments)
    }

    public func removeAll(owner: Owner) {
        commands = commands.filter { $0.value.owner != owner }
    }

    public var names: [String] { commands.keys.sorted() }

    /// `name - summary` per line: what the `commands` command returns, and the only
    /// documentation of the URL scheme that cannot go stale.
    public func listing() -> String {
        names.map { "\($0) - \(commands[$0]?.summary ?? "")" }.joined(separator: "\n")
    }

    /// `virtualdisplay://set-size?width=1280&height=720`. The host is the command name, so
    /// anything that can shell out to `open` is an automation client.
    @discardableResult
    public func perform(url: URL) throws -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Falls back to the path so both virtualdisplay://name and virtualdisplay:///name
        // work; the second is what some URL builders produce.
        let name = components?.host ?? ""
        let path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var pairs: [String: String] = [:]
        for item in components?.queryItems ?? [] { pairs[item.name] = item.value ?? "" }
        return try perform(name.isEmpty ? path : name, Arguments(pairs))
    }
}
