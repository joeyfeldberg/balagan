import Foundation
import XCTest
@testable import BalaganCore

final class AgentWrapperPlannerTests: XCTestCase {
    func testClaudeFreshSessionAddsSessionIDFlag() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--model", "sonnet"],
            environment: ["BALAGAN_CLAUDE_EXECUTABLE": "/tmp/fake-claude"],
            uuid: { uuid }
        )

        XCTAssertEqual(plan.agentName, "claude")
        XCTAssertEqual(plan.executablePath, "/tmp/fake-claude")
        XCTAssertEqual(plan.sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(plan.arguments, [
            "--session-id",
            "11111111-2222-3333-4444-555555555555",
            "--model",
            "sonnet",
        ])
        XCTAssertEqual(plan.command, "claude --resume 11111111-2222-3333-4444-555555555555")
    }

    func testClaudeResumeFlagIsCapturedWithoutAddingSessionID() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--resume", "resume-session-1", "--model", "opus"],
            environment: [:]
        )

        XCTAssertEqual(plan.sessionID, "resume-session-1")
        XCTAssertEqual(plan.arguments, ["--resume", "resume-session-1", "--model", "opus"])
        XCTAssertEqual(plan.command, "claude --resume resume-session-1")
    }

    func testClaudeSessionIDFlagIsCapturedWithoutAddingAnotherSessionID() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--session-id=22222222-3333-4444-5555-666666666666"],
            environment: [:]
        )

        XCTAssertEqual(plan.sessionID, "22222222-3333-4444-5555-666666666666")
        XCTAssertEqual(plan.arguments, ["--session-id=22222222-3333-4444-5555-666666666666"])
    }

    func testClaudeFreshSessionAddsNameFromEnvironment() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--model", "sonnet"],
            environment: [
                "BALAGAN_CLAUDE_EXECUTABLE": "/tmp/fake-claude",
                "BALAGAN_AGENT_NAME": "Build kanban shell",
            ],
            uuid: { uuid }
        )

        XCTAssertEqual(plan.arguments, [
            "--session-id",
            "11111111-2222-3333-4444-555555555555",
            "--name",
            "Build kanban shell",
            "--model",
            "sonnet",
        ])
    }

    func testClaudeDoesNotOverrideAnExplicitName() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--name", "chosen"],
            environment: ["BALAGAN_AGENT_NAME": "from-env"],
            uuid: { uuid }
        )

        XCTAssertEqual(plan.arguments, [
            "--session-id",
            "11111111-2222-3333-4444-555555555555",
            "--name",
            "chosen",
        ])
    }

    func testClaudeResumeDoesNotAddNameEvenWithEnv() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "claude", "--resume", "sess-1"],
            environment: ["BALAGAN_AGENT_NAME": "from-env"]
        )

        XCTAssertEqual(plan.arguments, ["--resume", "sess-1"])
    }

    func testBuildsValidSessionReportEventFromBalaganEnvironment() throws {
        let wrapperEnvironment = try AgentWrapperEnvironment.parse([
            "BALAGAN_TASK_ID": "task-1",
            "BALAGAN_WORKSPACE_ID": "workspace-1",
            "BALAGAN_SURFACE_ID": "surface-1",
            "BALAGAN_SOCKET_PATH": "/tmp/balagan.sock",
        ])
        let plan = AgentWrapperPlan(
            agentName: "claude",
            executablePath: "/tmp/fake-claude",
            arguments: ["--session-id", "session-1"],
            sessionID: "session-1",
            command: "claude --resume session-1",
            limitation: nil
        )

        let event = plan.sessionStartEvent(
            environment: wrapperEnvironment,
            processEnvironment: ["PATH": "/usr/bin:/bin"],
            cwd: "/tmp/balagan",
            pid: 1234,
            reportedAt: ISO8601DateFormatter().date(from: "2026-06-08T12:00:00Z")
        )
        let line = try SessionReportEventParser.encodeLine(event)
        let parsed = try SessionReportEventParser.parse(line.dropLast())

        XCTAssertEqual(parsed.event, .sessionStart)
        XCTAssertEqual(parsed.taskID, "task-1")
        XCTAssertEqual(parsed.workspaceID, "workspace-1")
        XCTAssertEqual(parsed.surfaceID, "surface-1")
        XCTAssertEqual(parsed.agentName, "claude")
        XCTAssertEqual(parsed.sessionID, "session-1")
        XCTAssertEqual(parsed.pid, 1234)
        XCTAssertEqual(parsed.executablePath, "/tmp/fake-claude")
        XCTAssertEqual(parsed.argv, ["/tmp/fake-claude", "--session-id", "session-1"])
        XCTAssertEqual(parsed.cwd, "/tmp/balagan")
        XCTAssertEqual(parsed.command, "claude --resume session-1")
        XCTAssertEqual(parsed.environment["PATH"], "/usr/bin:/bin")
    }

    func testRefusesOutsideBalaganEnvironment() throws {
        XCTAssertThrowsError(try AgentWrapperEnvironment.parse([
            "BALAGAN_TASK_ID": "task-1",
        ])) { error in
            XCTAssertEqual(
                error as? AgentWrapperError,
                .missingBalaganEnvironment([
                    "BALAGAN_SOCKET_PATH",
                    "BALAGAN_SURFACE_ID",
                    "BALAGAN_WORKSPACE_ID",
                ])
            )
        }
    }

    func testCodexReportsKnownSessionIDFromEnvironment() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "codex", "--model", "gpt-5"],
            environment: ["BALAGAN_AGENT_SESSION_ID": "codex-session-1"]
        )

        XCTAssertEqual(plan.agentName, "codex")
        XCTAssertEqual(plan.sessionID, "codex-session-1")
        XCTAssertEqual(plan.arguments, ["--model", "gpt-5"])
        XCTAssertEqual(plan.command, "codex resume codex-session-1")
        XCTAssertNil(plan.limitation)
    }

    func testCodexCapturesResumeSubcommandSessionID() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "codex", "resume", "codex-session-2", "--last"],
            environment: [:]
        )

        XCTAssertEqual(plan.sessionID, "codex-session-2")
        XCTAssertEqual(plan.command, "codex resume codex-session-2")
    }

    func testCodexFreshSessionSchedulesCaptureWithoutForegroundLimitation() throws {
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent", "codex", "--model", "gpt-5"],
            environment: [:]
        )

        XCTAssertNil(plan.sessionID)
        XCTAssertEqual(plan.command, "codex")
        XCTAssertNil(plan.limitation)
        XCTAssertTrue(plan.needsCodexSessionCapture)
    }
}
