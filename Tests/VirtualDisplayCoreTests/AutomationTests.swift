import XCTest
@testable import VirtualDisplayCore

/// The gate in front of the URL scheme. Everything a web page can reach goes through
/// `decision`, so these are the rules that decide whether a page can start a recording.
final class AutomationPolicyTests: XCTestCase {

    private let secret = "TOKEN-1234"

    private func withToken(_ rules: [String: AutomationPolicy.Rule] = [:]) -> AutomationPolicy {
        AutomationPolicy(requiresToken: true, token: secret, rules: rules)
    }

    private func asking(_ rules: [String: AutomationPolicy.Rule] = [:]) -> AutomationPolicy {
        AutomationPolicy(requiresToken: false, token: secret, rules: rules)
    }

    private func assertRefused(_ decision: AutomationPolicy.Decision,
                               _ why: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .refuse = decision else {
            return XCTFail(why, file: file, line: line)
        }
    }

    // MARK: The token gate

    func testTheRightTokenRunsTheCommand() {
        XCTAssertEqual(withToken().decision(command: "screenshot", presented: secret), .allow)
    }

    func testAMissingOrWrongTokenIsRefused() {
        let policy = withToken()
        assertRefused(policy.decision(command: "screenshot", presented: nil),
                      "a page supplies no token, which is the whole point")
        assertRefused(policy.decision(command: "screenshot", presented: "guess"),
                      "a wrong token is a wrong token")
    }

    /// No command is exempt. Moving the region is harmless on its own, and moving it onto
    /// something private and leaving it there is not, so the gate does not try to tell
    /// those apart.
    func testEveryCommandIsGuarded() {
        for command in ["set-size", "region", "state", "commands", "toggle-pause"] {
            assertRefused(withToken().decision(command: command, presented: nil),
                          "\(command) ran without the token")
            XCTAssertEqual(asking().decision(command: command, presented: nil),
                           .ask(remember: true), command)
        }
    }

    /// Defaults cleared, no token stored: an empty `token=` must not match an empty
    /// secret and open everything.
    func testAnEmptyStoredTokenMatchesNothing() {
        let policy = AutomationPolicy(requiresToken: true, token: "", rules: [:])
        assertRefused(policy.decision(command: "screenshot", presented: ""),
                      "empty is not a token")
        assertRefused(policy.decision(command: "screenshot", presented: nil),
                      "empty is not a token")
    }

    // MARK: Rules that hold whatever the token says

    /// The two layers answer different questions: the token says who is calling, the rule
    /// says whether they may. A right token is never permission, so there is no
    /// combination in which deny lets a call through.
    func testDenyRefusesEveryCombination() {
        for policy in [withToken(["start-recording": .deny]),
                       asking(["start-recording": .deny])] {
            for presented in [secret, "guess", ""] {
                assertRefused(policy.decision(command: "start-recording", presented: presented),
                              "deny let a call through carrying \"\(presented)\"")
            }
            assertRefused(policy.decision(command: "start-recording", presented: nil),
                          "deny let a call through with no token")
        }
    }

    /// The rule the user objected to having implicitly: a command only skips the token
    /// when it has been named as one that may.
    func testOnlyAcceptWithoutTokenSkipsTheToken() {
        XCTAssertEqual(withToken(["set-size": .acceptWithoutToken])
                        .decision(command: "set-size", presented: nil), .allow)
        // Allow is not a token waiver: it means "do not ask me", not "let anyone in".
        assertRefused(withToken(["set-size": .allow]).decision(command: "set-size", presented: nil),
                      "Allow must still require the token while one is required")
        // And the waiver is per command.
        assertRefused(withToken(["set-size": .acceptWithoutToken])
                        .decision(command: "screenshot", presented: nil),
                      "waiving one command must not waive the next")
    }

    func testAllowRunsOnceTheTokenIsAccepted() {
        XCTAssertEqual(withToken(["screenshot": .allow])
                        .decision(command: "screenshot", presented: secret), .allow)
        XCTAssertEqual(asking(["screenshot": .allow])
                        .decision(command: "screenshot", presented: nil), .allow)
    }

    // MARK: Asking

    func testAskOnceKeepsItsAnswerAndAlwaysAskDoesNot() {
        XCTAssertEqual(asking(["screenshot": .askOnce])
                        .decision(command: "screenshot", presented: nil), .ask(remember: true))
        XCTAssertEqual(asking(["screenshot": .alwaysAsk])
                        .decision(command: "screenshot", presented: nil), .ask(remember: false))
    }

    /// A command set to ask still needs the token first: a dialog must not be a way past
    /// the token for something that never presented one.
    func testAskingHappensAfterTheTokenNotInsteadOfIt() {
        let policy = withToken(["screenshot": .alwaysAsk])
        assertRefused(policy.decision(command: "screenshot", presented: nil),
                      "no token, so there is nothing to ask about")
        XCTAssertEqual(policy.decision(command: "screenshot", presented: secret),
                       .ask(remember: false))
    }

    func testTheDefaultAsksOnlyWhenNoTokenIsRequired() {
        XCTAssertEqual(withToken().decision(command: "screenshot", presented: secret), .allow)
        XCTAssertEqual(asking().decision(command: "screenshot", presented: nil),
                       .ask(remember: true))
    }

    /// The rules are per command: answering for one must not answer for the next.
    func testRulesDoNotLeakBetweenCommands() {
        XCTAssertEqual(asking(["screenshot": .allow])
                        .decision(command: "set-plugins", presented: nil), .ask(remember: true))
    }

    /// A rule made with the switch off survives turning it back on, which is what the
    /// alert promises when it says the answer is kept.
    func testRulesSurviveTheSwitch() {
        var policy = asking(["screenshot": .deny, "set-size": .acceptWithoutToken])
        policy.requiresToken = true
        assertRefused(policy.decision(command: "screenshot", presented: secret),
                      "a deny is still a deny with the token on")
        XCTAssertEqual(policy.decision(command: "set-size", presented: nil), .allow)
    }
}

/// Splitting the URL apart before running anything is what lets the gate see which
/// command is being asked for.
@MainActor
final class URLCallTests: XCTestCase {

    func testHostAndPathBothNameTheCommand() throws {
        let host = CommandCenter.parse(url: try XCTUnwrap(URL(string: "virtualdisplay://set-size?name=1280")))
        XCTAssertEqual(host.name, "set-size")
        XCTAssertEqual(host.arguments["name"], "1280")

        // What some URL builders produce.
        let path = CommandCenter.parse(url: try XCTUnwrap(URL(string: "virtualdisplay:///screenshot")))
        XCTAssertEqual(path.name, "screenshot")
    }

    /// The token belongs to the gate. A command that sees it would have to know to ignore
    /// it, and `set-overlay` would draw it into the shared window as an overlay id.
    func testTheTokenIsStrippedBeforeTheCommandRuns() throws {
        let call = CommandCenter.parse(
            url: try XCTUnwrap(URL(string: "virtualdisplay://screenshot?token=abc&path=/tmp/x.png")))
        let passed = call.arguments.removing(AutomationPolicy.tokenArgument)
        XCTAssertNil(passed["token"])
        XCTAssertEqual(passed["path"], "/tmp/x.png")
    }

    /// The permission list in settings is fed from the table itself, so a command cannot
    /// exist without a row to answer for it, plugin commands included.
    func testThePermissionListIsTheWholeTable() {
        let center = CommandCenter()
        center.register("screenshot", "Save a PNG") { _ in nil }
        center.register("set-size", "Resize the region") { _ in nil }
        center.register("plugin-thing", "Added by a plugin", owner: .plugin) { _ in nil }
        XCTAssertEqual(center.names, ["plugin-thing", "screenshot", "set-size"])

        // The description beside each row is the summary it was registered with, so the
        // two cannot drift apart.
        XCTAssertEqual(center.catalog.map(\.summary),
                       ["Added by a plugin", "Save a PNG", "Resize the region"])
    }
}
