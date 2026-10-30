import XCTest
@testable import BalaganCore

final class AgentHookDecisionTests: XCTestCase {
    private let env = AgentWrapperEnvironment(taskID: "task-1", workspaceID: "ws-1", surfaceID: "s-1", socketPath: "/tmp/x.sock")

    private func decide(_ event: AgentHookEvent, _ payload: AgentHookPayload, env: AgentWrapperEnvironment?) -> AgentHookDecision {
        event.decision(payload: payload, balaganEnvironment: env, processEnvironment: ["K": "V"], currentDirectory: "/repo")
    }

    func testPermissionRequestSendsNeedsInputForTheSurface() {
        let decision = decide(.permissionRequest, AgentHookPayload(sessionID: "abc", toolName: "Bash"), env: env)
        guard case let .send(event, lifecycle, toolName) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(lifecycle, .needsInput)
        XCTAssertEqual(toolName, "Bash")
        XCTAssertEqual(event.surfaceID, "s-1")
        XCTAssertEqual(event.lifecycle, "needs-input")
        XCTAssertEqual(event.command, "claude --resume abc")
        XCTAssertEqual(event.cwd, "/repo", "falls back to the current directory")
        XCTAssertEqual(event.environment, ["K": "V"])
    }

    func testSubagentHooksAreDroppedButTheirSessionStartIsNot() {
        let subagent = AgentHookPayload(sessionID: "abc", toolName: "Read", agentID: "sub-1")
        XCTAssertEqual(decide(.preTool, subagent, env: env), .drop(.droppedSubagent, lifecycle: nil, toolName: "Read"))
        guard case .send = decide(.sessionStart, subagent, env: env) else { return XCTFail("session start dropped") }
    }

    func testDropReasons() {
        XCTAssertEqual(
            decide(.preTool, AgentHookPayload(toolName: "Bash"), env: nil),
            .drop(.droppedMissingEnv, lifecycle: .running, toolName: "Bash")
        )
        XCTAssertEqual(
            decide(.sessionStart, AgentHookPayload(), env: env),
            .drop(.droppedNoSessionID, lifecycle: .idle, toolName: nil)
        )
        XCTAssertEqual(
            decide(.notification, AgentHookPayload(notificationType: "something-new"), env: env),
            .drop(.droppedNoMapping, lifecycle: nil, toolName: nil)
        )
    }
}
