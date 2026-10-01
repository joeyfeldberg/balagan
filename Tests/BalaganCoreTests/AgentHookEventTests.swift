import Foundation
import XCTest
@testable import BalaganCore

/// The hook contract: which Claude hook means which working state, and which payloads must be ignored.
/// This is the whole of the agent working-state detection that is testable without a live agent.
final class AgentHookEventTests: XCTestCase {
    private func report(_ event: AgentHookEvent, _ payload: AgentHookPayload = AgentHookPayload()) -> AgentHookEvent.Report? {
        event.report(payload: payload)
    }

    // MARK: - Event parsing

    func testUnknownOrMissingArgumentFallsBackToSessionStart() {
        XCTAssertEqual(AgentHookEvent(argument: nil), .sessionStart)
        XCTAssertEqual(AgentHookEvent(argument: "not-a-hook"), .sessionStart)
        XCTAssertEqual(AgentHookEvent(argument: "Permission-Request"), .permissionRequest)
        XCTAssertEqual(AgentHookEvent(argument: "post-tool"), .postTool)
    }

    // MARK: - Working-state mapping

    /// `PermissionRequest` is the whole point of the new contract: it fires *before* the dialog is
    /// drawn, where `Notification`/`permission_prompt` only fires 6 s later (and not at all if the user
    /// answers sooner).
    func testPermissionRequestIsNeedsInputAndCarriesTheTool() {
        let result = report(.permissionRequest, AgentHookPayload(toolName: "Bash"))
        XCTAssertEqual(result?.kind, .lifecycle)
        XCTAssertEqual(result?.lifecycle, .needsInput)
        XCTAssertEqual(result?.toolName, "Bash")
    }

    /// A finished tool means work resumed — this is what clears the needs-input left by an approved
    /// permission prompt (PreToolUse already ran *before* the dialog).
    func testPostToolIsRunning() {
        XCTAssertEqual(report(.postTool, AgentHookPayload(toolName: "Bash"))?.lifecycle, .running)
    }

    func testPromptSubmitIsRunningAndStopIsIdle() {
        XCTAssertEqual(report(.promptSubmit)?.lifecycle, .running)
        XCTAssertEqual(report(.stop)?.lifecycle, .idle)
    }

    func testPreToolIsRunningForOrdinaryTools() {
        XCTAssertEqual(report(.preTool, AgentHookPayload(toolName: "Read"))?.lifecycle, .running)
        XCTAssertEqual(report(.preTool)?.lifecycle, .running, "no tool_name still reads as a heartbeat")
    }

    /// Belt-and-braces alongside PermissionRequest: these two tools hand control back to the user
    /// without going through the permission dialog.
    func testPreToolIsNeedsInputForUserBlockingTools() {
        XCTAssertEqual(report(.preTool, AgentHookPayload(toolName: "AskUserQuestion"))?.lifecycle, .needsInput)
        XCTAssertEqual(report(.preTool, AgentHookPayload(toolName: "ExitPlanMode"))?.lifecycle, .needsInput)
    }

    func testNotificationDelegatesToTheClassifier() {
        XCTAssertEqual(report(.notification, AgentHookPayload(notificationType: "permission_prompt"))?.lifecycle, .needsInput)
        XCTAssertEqual(report(.notification, AgentHookPayload(notificationType: "idle_prompt"))?.lifecycle, .idle)
        XCTAssertNil(report(.notification, AgentHookPayload(notificationType: "quota_auto_resume_armed")))
        XCTAssertNil(report(.notification), "no notification_type → stay silent")
    }

    func testSessionStartReportsTheSessionNotAWorkingState() {
        let result = report(.sessionStart, AgentHookPayload(sessionID: "sess-1"))
        XCTAssertEqual(result?.kind, .sessionStart)
    }

    // MARK: - Subagent gating

    /// A background subagent's tool traffic fires the same hooks on the same surface. Letting it drive
    /// the lifecycle re-asserted "running" over a real needs-input on the parent surface.
    func testSubagentLifecycleEventsAreDropped() {
        let subagent = AgentHookPayload(toolName: "Bash", agentID: "agent-7")
        for event in AgentHookEvent.allCases where event != .sessionStart {
            var payload = subagent
            payload.notificationType = "permission_prompt"
            XCTAssertNil(event.report(payload: payload), "\(event.rawValue) must ignore subagent payloads")
        }
    }

    /// …but the session id a subagent's SessionStart carries is still the parent conversation's, so
    /// resume capture keeps working.
    func testSubagentSessionStartStillReports() {
        let result = report(.sessionStart, AgentHookPayload(sessionID: "sess-1", agentID: "agent-7"))
        XCTAssertEqual(result?.kind, .sessionStart)
    }

    // MARK: - Payload parsing

    func testParsesRealHookPayloadFields() {
        let json = """
        {
          "session_id": "sess-1",
          "transcript_path": "/tmp/sess-1.jsonl",
          "cwd": "/tmp/work",
          "tool_name": "Bash",
          "tool_input": {"command": "ls"},
          "hook_event_name": "PermissionRequest"
        }
        """
        let payload = AgentHookPayload.parse(Data(json.utf8))
        XCTAssertEqual(payload.sessionID, "sess-1")
        XCTAssertEqual(payload.transcriptPath, "/tmp/sess-1.jsonl")
        XCTAssertEqual(payload.cwd, "/tmp/work")
        XCTAssertEqual(payload.toolName, "Bash")
        XCTAssertNil(payload.agentID)
    }

    func testParsesBlankAndInvalidPayloadsAsEmpty() {
        XCTAssertEqual(AgentHookPayload.parse(Data()), AgentHookPayload())
        XCTAssertEqual(AgentHookPayload.parse(Data("not json".utf8)), AgentHookPayload())
        XCTAssertEqual(AgentHookPayload.parse(Data(#"{"agent_id": "  "}"#.utf8)), AgentHookPayload())
    }

    // MARK: - Injected --settings

    func testInjectedSettingsRegisterEveryHookAndDisableClaudeNotifications() throws {
        let json = try ClaudeHookSettings.json(wrapperPath: "/Applications/Balagan.app/Contents/MacOS/balagan-agent")
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertEqual(decoded["preferredNotifChannel"] as? String, "notifications_disabled")

        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Notification"]
        )

        let matchers = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let commands = try XCTUnwrap(matchers.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.first?["type"] as? String, "command")
        XCTAssertEqual(
            commands.first?["command"] as? String,
            "'/Applications/Balagan.app/Contents/MacOS/balagan-agent' hook permission-request"
        )
    }

    /// A path with a quote in it must not be able to break out of the hook command line.
    func testWrapperPathIsShellQuoted() throws {
        let json = try ClaudeHookSettings.json(wrapperPath: "/tmp/it's here/balagan-agent")
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: Any])
        let matchers = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = try XCTUnwrap(matchers.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.first?["command"] as? String, #"'/tmp/it'\''s here/balagan-agent' hook stop"#)
    }
}
