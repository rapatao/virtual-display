import Foundation

/// Who is allowed to drive the app over `virtualdisplay://`.
///
/// The scheme is open to anything that can ask macOS to open a URL, a web page included.
/// The only thing in front of it is the browser's own "Open Virtual Display?" prompt,
/// which does not say that answering yes may start a screen recording.
///
/// Two separate layers, both of which have to be satisfied:
///
/// - the **token** authenticates the caller, saying the URL came from something the user
///   set up rather than from a page they happened to visit;
/// - the **rule** authorises the command, saying whether that caller may run this one.
///
/// A right token is never permission. `deny` refuses a call carrying a perfect token,
/// because the question the token answers is not the question the rule answers.
///
/// Every command, not a chosen few: which of them is worth guarding is a judgement that
/// ages badly, and one that gets it wrong is a hole nobody notices. A page that can drive
/// the app at all can move the region onto something private and leave it there.
///
/// Commands reaching the app any other way, the menu, a shortcut, a `config.json` hotkey,
/// a Lua plugin, are not subject to any of this. They are already the user acting.
public struct AutomationPolicy: Equatable, Sendable {

    /// What one command does when a URL asks for it. Absent is the default: the token
    /// requirement decides, which is what almost every command should do.
    ///
    /// Order is least to most permissive, which is the order the picker shows.
    public enum Rule: String, Equatable, Sendable, CaseIterable {
        /// Refused however good the token is. This is what a token cannot do on its own:
        /// tokens end up in shell history, in a dotfiles repo, in a screenshot of the
        /// window that shows them, and a command set to deny is still refused after one
        /// leaks.
        case deny
        /// Prompt on every single call, and never remember the answer.
        case alwaysAsk
        /// Prompt until answered, then keep that answer.
        case askOnce
        /// No prompt. Still needs the token while the token is required.
        case allow
        /// The only way past the token, and it has to be asked for by name. For the
        /// button pressed fifty times a day, without weakening anything else.
        case acceptWithoutToken
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Put the question to the user. `remember: false` is `alwaysAsk`, where the
        /// answer must not be stored.
        case ask(remember: Bool)
        /// Refused outright, with something to tell the user.
        case refuse(String)
    }

    /// The token gate. While this is on, a valid token is required for everything except
    /// the commands explicitly set to `acceptWithoutToken`.
    public var requiresToken: Bool
    public var token: String
    /// Per-command rules, by command name. Absent means the default.
    public var rules: [String: Rule]

    public init(requiresToken: Bool = true, token: String = "",
                rules: [String: Rule] = [:]) {
        self.requiresToken = requiresToken
        self.token = token
        self.rules = rules
    }

    /// Applies to every command by name, including any a plugin registered.
    ///
    /// The two layers are separate and both have to be satisfied. The token authenticates
    /// the caller: it says the URL came from something the user set up rather than from a
    /// page they happened to visit. The rule authorises the command: it says whether that
    /// caller may run this one at all. A right token never overrides a rule, which is why
    /// `deny` is answered here and never reaches the token check below.
    public func decision(command: String, presented: String?) -> Decision {
        switch rules[command] {
        case .deny:
            return .refuse("\"\(command)\" is set to Deny in Settings > Automation.")
        // The single, named waiver, and the only branch that does not consult the token.
        case .acceptWithoutToken:
            return .allow
        case .allow:
            return tokenRefusal(presented, for: command) ?? .allow
        case .alwaysAsk:
            return tokenRefusal(presented, for: command) ?? .ask(remember: false)
        case .askOnce:
            return tokenRefusal(presented, for: command) ?? .ask(remember: true)
        case nil:
            // No rule of its own: a good token is the answer. With no token required there
            // is nothing else to go on, so ask, and keep what is said.
            return tokenRefusal(presented, for: command)
                ?? (requiresToken ? .allow : .ask(remember: true))
        }
    }

    /// Why the token stops this call, or `nil` when it does not stand in the way. Asking
    /// is never a way around it: a rule that prompts still comes through here first, so a
    /// caller with no token is refused rather than offered a dialog.
    private func tokenRefusal(_ presented: String?, for command: String) -> Decision? {
        guard requiresToken else { return nil }
        // An empty stored token can never be matched, including by an empty `token=`.
        guard !token.isEmpty, let presented, presented == token else {
            return .refuse("\"\(command)\" needs the automation token. "
                           + "Copy it from Settings > Automation and add it as "
                           + "token=... to the URL.")
        }
        return nil
    }

    /// The query item the token travels in. Stripped before the command sees its
    /// arguments, so no command has to know the gate exists.
    public static let tokenArgument = "token"

    /// A token is a shared secret in a URL that turns up in shell history and browser
    /// logs, so it is worth being able to replace.
    public static func freshToken() -> String {
        UUID().uuidString
    }
}
