import XCTest
@testable import BalaganCore

/// Forking a tab's session: each agent's own fork command, and the wrapper binding the tab to the
/// *new* session rather than the original it forked from.
final class SessionForkTests: XCTestCase {
    func testEachBuiltInForksWithItsOwnCommand() {
        XCTAssertEqual(AgentProfiles.claude.forkArgv(sessionID: "abc"), ["claude", "--resume", "abc", "--fork-session"])
        XCTAssertEqual(AgentProfiles.codex.forkArgv(sessionID: "abc"), ["codex", "fork", "abc"])
        XCTAssertEqual(AgentProfiles.opencode.forkArgv(sessionID: "abc"), ["opencode", "--session", "abc", "--fork"])
        XCTAssertEqual(AgentProfiles.pi.forkArgv(sessionID: "abc"), ["pi", "--fork", "abc"])
        XCTAssertNil(AgentProfile(id: "custom", displayName: "Custom", command: "custom").forkArgv(sessionID: "abc"))
    }

    func testAForkIsToldApartFromAResume() {
        XCTAssertTrue(AgentProfiles.claude.isFork(arguments: ["--resume", "abc", "--fork-session"]))
        XCTAssertFalse(AgentProfiles.claude.isFork(arguments: ["--resume", "abc"]))
        XCTAssertTrue(AgentProfiles.codex.isFork(arguments: ["fork", "abc"]))
        XCTAssertFalse(AgentProfiles.codex.isFork(arguments: ["resume", "abc"]))
        XCTAssertTrue(AgentProfiles.pi.isFork(arguments: ["--fork", "abc"]))
        XCTAssertFalse(AgentProfiles.pi.isFork(arguments: ["--session-id", "abc"]))
        XCTAssertTrue(AgentProfiles.opencode.isFork(arguments: ["--session", "abc", "--fork"]))
        XCTAssertFalse(AgentProfiles.opencode.isFork(arguments: ["--session", "abc"]))
    }

    func testClaudeForkIsNamedUpFrontSoTheTabBindsToTheFork() throws {
        let uuid = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--resume", "original-1", "--fork-session"],
            environment: ["BALAGAN_CLAUDE_EXECUTABLE": "/tmp/fake-claude"],
            uuid: { uuid }
        )
        XCTAssertEqual(plan.sessionID, "99999999-2222-3333-4444-555555555555")
        XCTAssertEqual(plan.arguments, [
            "--session-id", "99999999-2222-3333-4444-555555555555", "--resume", "original-1", "--fork-session",
        ])
        XCTAssertEqual(plan.command, "claude --resume 99999999-2222-3333-4444-555555555555")
    }

    func testCodexForkIsCapturedLikeAFreshStart() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "codex", "fork", "original-1"],
            environment: ["BALAGAN_CODEX_EXECUTABLE": "/tmp/fake-codex"]
        )
        XCTAssertNil(plan.sessionID)
        XCTAssertTrue(plan.needsCodexSessionCapture)
        XCTAssertEqual(plan.arguments, ["fork", "original-1"])
    }

    func testPiForkLeavesTheSessionToItsExtension() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "pi", "--fork", "original-1"],
            environment: ["BALAGAN_PI_EXECUTABLE": "/tmp/fake-pi"]
        )
        XCTAssertNil(plan.sessionID, "the id after --fork is the original's")
        XCTAssertEqual(plan.arguments, ["--fork", "original-1"])
    }
}
