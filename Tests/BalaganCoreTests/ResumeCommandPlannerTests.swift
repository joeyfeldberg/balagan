import XCTest
@testable import BalaganCore

final class ResumeCommandPlannerTests: XCTestCase {
    func testCodexResumeUsesNativeArgv() {
        let binding = ResumeBinding(
            id: "resume-codex",
            surfaceID: "surface-agent",
            kind: .agent,
            agentName: "codex",
            sessionID: "session-123",
            command: "codex resume session-123",
            trust: .trusted,
            source: .agentHook,
            pid: 1122,
            executablePath: "/opt/homebrew/bin/codex",
            argv: ["codex"],
            cwd: "/repo",
            capturedAt: BalaganFixtures.baseDate,
            captureUpdatedAt: BalaganFixtures.baseDate,
            wasRunning: true,
            autoResume: true,
            createdAt: BalaganFixtures.baseDate,
            updatedAt: BalaganFixtures.baseDate
        )

        let plan = ResumeCommandPlanner.plan(for: binding, taskID: "task-1", cwd: "/repo")

        XCTAssertEqual(plan.argv, ["codex", "resume", "session-123"])
        XCTAssertEqual(plan.displayCommand, "codex resume session-123")
        XCTAssertEqual(plan.agentName, "codex")
        XCTAssertEqual(plan.sessionID, "session-123")
        XCTAssertFalse(plan.requiresConfirmation)
    }

    func testCapturedClaudeResumeUsesNativeArgv() {
        let binding = ResumeBinding(
            id: "resume-claude",
            surfaceID: "surface-agent",
            kind: .agent,
            agentName: "claude",
            sessionID: "claude-session-123",
            command: "claude --resume claude-session-123",
            trust: .trusted,
            source: .agentHook,
            pid: 2233,
            executablePath: "/opt/homebrew/bin/claude",
            argv: ["claude"],
            cwd: "/repo",
            capturedAt: BalaganFixtures.baseDate,
            captureUpdatedAt: BalaganFixtures.baseDate,
            wasRunning: true,
            autoResume: true,
            createdAt: BalaganFixtures.baseDate,
            updatedAt: BalaganFixtures.baseDate
        )

        let plan = ResumeCommandPlanner.plan(for: binding, taskID: "task-1", cwd: "/repo")

        // Claude resumes the captured session id; the SessionStart hook keeps that id current across
        // in-agent `/resume`, so the precise (per-surface) id is the right resume target.
        XCTAssertEqual(plan.argv, ["claude", "--resume", "claude-session-123"])
        XCTAssertEqual(plan.displayCommand, "claude --resume claude-session-123")
        XCTAssertEqual(plan.agentName, "claude")
        XCTAssertEqual(plan.sessionID, "claude-session-123")
        XCTAssertFalse(plan.requiresConfirmation)
    }

    func testTmuxResumeUsesCapturedSessionID() {
        let binding = ResumeBinding(
            id: "resume-tmux",
            surfaceID: "surface-shell",
            kind: .tmux,
            sessionID: "task_task-1",
            command: "tmux attach -t task_task-1",
            trust: .untrusted,
            createdAt: BalaganFixtures.baseDate,
            updatedAt: BalaganFixtures.baseDate
        )

        let plan = ResumeCommandPlanner.plan(for: binding, taskID: "task-1", cwd: "/repo")

        XCTAssertEqual(plan.argv, ["tmux", "attach", "-t", "task_task-1"])
        XCTAssertEqual(plan.displayCommand, "tmux attach -t task_task-1")
        XCTAssertEqual(plan.sessionID, "task_task-1")
        XCTAssertTrue(plan.requiresConfirmation)
    }

    func testTmuxResumeFallsBackToTaskID() {
        let binding = ResumeBinding(
            id: "resume-tmux",
            surfaceID: "surface-shell",
            kind: .tmux,
            command: "",
            trust: .trusted,
            createdAt: BalaganFixtures.baseDate,
            updatedAt: BalaganFixtures.baseDate
        )

        let plan = ResumeCommandPlanner.plan(for: binding, taskID: "ABC 123:feature/UI", cwd: "/repo")

        XCTAssertEqual(plan.argv, ["tmux", "attach", "-t", "task_abc_123_feature_ui"])
        XCTAssertFalse(plan.requiresConfirmation)
    }

    func testCustomResumeDoesNotCreateArgv() {
        let binding = ResumeBinding(
            id: "resume-custom",
            surfaceID: "surface-shell",
            kind: .custom,
            command: "custom resume --dangerous 'quoted value'",
            trust: .trusted,
            createdAt: BalaganFixtures.baseDate,
            updatedAt: BalaganFixtures.baseDate
        )

        let plan = ResumeCommandPlanner.plan(for: binding, taskID: "task-1", cwd: "/repo")

        XCTAssertNil(plan.argv)
        XCTAssertEqual(plan.displayCommand, "custom resume --dangerous 'quoted value'")
        XCTAssertTrue(plan.requiresConfirmation)
    }
}
