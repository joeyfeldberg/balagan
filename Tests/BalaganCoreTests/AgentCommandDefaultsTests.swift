import XCTest
@testable import BalaganCore

final class AgentCommandDefaultsTests: XCTestCase {
    func testDefaultCommandsUseBalaganAgentWrapper() {
        XCTAssertEqual(AgentCommandDefaults.codex, "balagan-agent codex")
        XCTAssertEqual(AgentCommandDefaults.claude, "balagan-agent claude")
        XCTAssertEqual(AgentCommandDefaults.preferred, AgentCommandDefaults.codex)
    }

    func testResolverKeepsStableCommandWhenWrapperPathIsNotInjected() {
        let command = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: " balagan-agent codex ",
            environment: [:]
        )

        XCTAssertEqual(command, "balagan-agent codex")
    }

    func testResolverUsesSwiftPMWrapperPathWhenInjected() {
        let command = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: "balagan-agent claude --model sonnet",
            environment: ["BALAGAN_AGENT_WRAPPER_PATH": "/tmp/balagan build/balagan-agent"]
        )

        XCTAssertEqual(command, "'/tmp/balagan build/balagan-agent' claude --model sonnet")
    }

    func testResolverUsesExplicitWrapperPathBeforeEnvironment() {
        let command = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: "balagan-agent codex",
            environment: ["BALAGAN_AGENT_WRAPPER_PATH": "/tmp/stale/balagan-agent"],
            wrapperPath: "/tmp/current build/balagan-agent"
        )

        XCTAssertEqual(command, "'/tmp/current build/balagan-agent' codex")
    }

    func testResolverLeavesOrdinaryCommandsAlone() {
        let command = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: "codex",
            environment: ["BALAGAN_AGENT_WRAPPER_PATH": "/tmp/balagan-agent"]
        )

        XCTAssertEqual(command, "codex")
    }

    func testBlankDefaultDoesNotCreateAgentStartupCommand() {
        XCTAssertNil(AgentStartupCommandResolver.startupCommand(defaultAgentCommand: "  "))
        XCTAssertNil(AgentStartupCommandResolver.startupCommand(defaultAgentCommand: nil))
    }

    func testProjectDefaultCanBecomeAgentSurfaceStartupCommand() throws {
        let project = BalaganFixtures.project(defaultAgentCommand: AgentCommandDefaults.codex)
        let startupCommand = try XCTUnwrap(AgentStartupCommandResolver.startupCommand(
            for: project,
            environment: ["BALAGAN_AGENT_WRAPPER_PATH": "/tmp/balagan-agent"]
        ))
        let surface = BalaganFixtures.surface(startupCommand: startupCommand, resumeBinding: nil)

        let request = try XCTUnwrap(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))

        XCTAssertEqual(request.source, .startupCommand)
        XCTAssertEqual(request.displayCommand, "'/tmp/balagan-agent' codex")
        XCTAssertEqual(request.command.arguments, ["-lc", "'/tmp/balagan-agent' codex"])
    }

    func testCapturedResumeLaunchIgnoresResolvedAgentDefaultStartupCommand() throws {
        let startupCommand = try XCTUnwrap(AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: AgentCommandDefaults.codex,
            wrapperPath: "/tmp/balagan-agent"
        ))
        let binding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "codex",
            sessionID: "captured-session-123",
            command: "codex resume captured-session-123",
            trust: .trusted,
            source: .agentHook,
            autoResume: true
        )
        let surface = BalaganFixtures.surface(startupCommand: startupCommand, resumeBinding: binding)

        let request = try XCTUnwrap(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))

        XCTAssertEqual(request.source, .trustedResume)
        XCTAssertEqual(request.displayCommand, "codex resume captured-session-123")
        XCTAssertEqual(request.command.executable, "codex")
        XCTAssertEqual(request.command.arguments, ["resume", "captured-session-123"])
    }

    func testProjectDefaultDoesNotLeakIntoOrdinaryShellSurface() {
        let project = BalaganFixtures.project(defaultAgentCommand: AgentCommandDefaults.codex)
        let shellSurface = BalaganFixtures.surface(startupCommand: nil, resumeBinding: nil)

        XCTAssertNotNil(project.defaultAgentCommand)
        guard case .startupShell(let command) = ResumeLaunchPolicy.action(for: shellSurface, taskID: "build-board") else {
            return XCTFail("Expected ordinary terminal surface without startup command to launch the default shell.")
        }
        XCTAssertEqual(command.argv, [UserShell.defaultShellPath(environment: shellSurface.environment)])
    }
}
