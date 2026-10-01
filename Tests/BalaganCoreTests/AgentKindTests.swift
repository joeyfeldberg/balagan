import XCTest
@testable import BalaganCore

/// `AgentKind` is derived from what a surface already stores — nothing mirrors it — so these lock down
/// the derivation order (wrapper-reported name first, launch command as the fallback) and the one
/// false-positive that substring matching used to produce.
final class AgentKindTests: XCTestCase {
    private func surface(
        startupCommand: String? = nil,
        resumeBinding: ResumeBinding? = nil,
        launchMetadata: AgentLaunchMetadata? = nil
    ) -> Surface {
        Surface(
            id: "agent",
            workspaceID: "workspace",
            title: "agent",
            cwd: "/tmp",
            startupCommand: startupCommand,
            resumeBinding: resumeBinding,
            agentLaunchMetadata: launchMetadata
        )
    }

    private func binding(agentName: String?, command: String, argv: [String] = []) -> ResumeBinding {
        ResumeBinding(
            id: "resume-agent",
            surfaceID: "agent",
            kind: agentName == nil ? .tmux : .agent,
            agentName: agentName,
            command: command,
            argv: argv
        )
    }

    func testNamedMatchesTheWrapperReportedAgentName() {
        XCTAssertEqual(AgentKind.named("codex"), .codex)
        XCTAssertEqual(AgentKind.named("Claude"), .claude)
        XCTAssertNil(AgentKind.named(nil))
        XCTAssertNil(AgentKind.named("  "))
        XCTAssertNil(AgentKind.named("aider"))
    }

    func testCommandMatchingIsPerTokenNotSubstring() {
        XCTAssertEqual(AgentKind.inCommand("balagan-agent codex"), .codex)
        XCTAssertEqual(AgentKind.inCommand("'/Users/j/.build/debug/balagan-agent' claude --foo"), .claude)
        XCTAssertEqual(AgentKind.inCommand("/opt/homebrew/bin/codex resume 4f7e"), .codex)
        // The bug per-token matching prevents: a tmux session *named* after codex runs no agent.
        XCTAssertNil(AgentKind.inCommand("tmux attach -t task_resume_codex"))
        XCTAssertNil(AgentKind.inCommand("/usr/local/bin/codex-helper --watch"))
        XCTAssertNil(AgentKind.inCommand("zsh -l"))
        XCTAssertNil(AgentKind.inCommand(nil))
    }

    func testSurfacePrefersTheCapturedAgentNameOverTheCommand() {
        let resumed = surface(
            startupCommand: "balagan-agent codex",
            resumeBinding: binding(agentName: "claude", command: "claude --resume abc")
        )
        XCTAssertEqual(resumed.agentKind, .claude, "the wrapper reported the name; it wins")
    }

    func testSurfaceFallsBackToTheLaunchCommandBeforeCapture() {
        XCTAssertEqual(surface(startupCommand: "balagan-agent codex").agentKind, .codex)
        XCTAssertEqual(surface(startupCommand: "balagan-agent claude").agentKind, .claude)
        XCTAssertEqual(
            surface(launchMetadata: AgentLaunchMetadata(
                agentName: "codex",
                startupCommand: "balagan-agent codex",
                cwd: "/tmp",
                launchedAtMs: 0
            )).agentKind,
            .codex
        )
    }

    func testPlainShellAndTmuxSurfacesHaveNoAgentKind() {
        XCTAssertNil(surface().agentKind)
        XCTAssertNil(surface(startupCommand: "zsh -l").agentKind)
        XCTAssertNil(
            surface(resumeBinding: binding(agentName: nil, command: "tmux attach -t task_resume_codex")).agentKind
        )
    }
}
