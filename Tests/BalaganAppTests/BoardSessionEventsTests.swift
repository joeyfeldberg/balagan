import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Area (d): `applyReportedSessionCapture` in `BoardSessionEvents` — a session-start report lands a
/// resume binding on the matching surface, mismatched task/workspace/surface ids are ignored, and a
/// session-end report clears the binding's running flag.
final class BoardSessionEventsTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    private func surface(_ viewModel: BoardViewModel, _ taskID: TaskItem.ID, _ surfaceID: Surface.ID) -> Surface {
        viewModel.tasks.first { $0.id == taskID }!.workspace.surfaces.first { $0.id == surfaceID }!
    }

    func testApplySessionStartBindsResumeToSurface() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        let task = viewModel.tasks.first { $0.id == taskID }!
        let workspaceID = task.workspace.id
        let surfaceID = task.workspace.surfaces[0].id

        let event = SessionReportEvent(
            event: .sessionStart,
            taskID: taskID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentName: "codex",
            sessionID: "sess-123",
            cwd: "/tmp/work"
        )

        let result = viewModel.applyReportedSessionCapture(event)

        XCTAssertEqual(result.status, "applied")
        XCTAssertNotNil(result.resumeCommand)
        let bound = surface(viewModel, taskID, surfaceID)
        XCTAssertEqual(bound.resumeBinding?.sessionID, "sess-123")
        XCTAssertEqual(bound.resumeBinding?.agentName, "codex")
        XCTAssertEqual(bound.resumeBinding?.kind, .agent)
        XCTAssertEqual(bound.resumeBinding?.wasRunning, true)
        XCTAssertEqual(bound.cwd, "/tmp/work")
    }

    func testApplySessionStartIgnoresWorkspaceMismatch() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        let surfaceID = viewModel.tasks.first { $0.id == taskID }!.workspace.surfaces[0].id

        let event = SessionReportEvent(
            event: .sessionStart,
            taskID: taskID,
            workspaceID: "not-the-right-workspace",
            surfaceID: surfaceID,
            agentName: "codex",
            sessionID: "sess-123"
        )

        let result = viewModel.applyReportedSessionCapture(event)

        XCTAssertEqual(result.status, "ignored")
        XCTAssertNil(surface(viewModel, taskID, surfaceID).resumeBinding)
    }

    func testApplySessionStartTranscriptPathCapturePreserveAndReset() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        let task = viewModel.tasks.first { $0.id == taskID }!
        let workspaceID = task.workspace.id
        let surfaceID = task.workspace.surfaces[0].id
        func sessionStart(_ sessionID: String, transcriptPath: String?) -> SessionReportEvent {
            SessionReportEvent(
                event: .sessionStart,
                taskID: taskID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                agentName: "claude",
                sessionID: sessionID,
                transcriptPath: transcriptPath
            )
        }

        // Wrapper pre-exec report has no transcript yet.
        _ = viewModel.applyReportedSessionCapture(sessionStart("sess-1", transcriptPath: nil))
        XCTAssertNil(surface(viewModel, taskID, surfaceID).resumeBinding?.transcriptPath)

        // The SessionStart hook supplies it.
        _ = viewModel.applyReportedSessionCapture(sessionStart("sess-1", transcriptPath: "/tmp/sess-1.jsonl"))
        XCTAssertEqual(surface(viewModel, taskID, surfaceID).resumeBinding?.transcriptPath, "/tmp/sess-1.jsonl")

        // A same-session report without a transcript must not wipe the known path.
        _ = viewModel.applyReportedSessionCapture(sessionStart("sess-1", transcriptPath: nil))
        XCTAssertEqual(surface(viewModel, taskID, surfaceID).resumeBinding?.transcriptPath, "/tmp/sess-1.jsonl")

        // A new session id (in-agent /resume) invalidates the old transcript.
        _ = viewModel.applyReportedSessionCapture(sessionStart("sess-2", transcriptPath: nil))
        XCTAssertNil(surface(viewModel, taskID, surfaceID).resumeBinding?.transcriptPath)
    }

    /// The hook-driven working state: a `.lifecycle` report moves the surface through
    /// needs-input → running → idle. This is the app end of the `AgentHookEvent` contract —
    /// PermissionRequest → needs-input, PostToolUse (approved, tool finished) → running, Stop → idle.
    func testApplyLifecycleReportsMoveSurfaceWorkingState() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        let task = viewModel.tasks.first { $0.id == taskID }!
        let workspaceID = task.workspace.id
        let surfaceID = task.workspace.surfaces[0].id
        func lifecycle(_ value: String, toolName: String? = nil) -> SessionReportApplyResult {
            viewModel.applyReportedSessionCapture(SessionReportEvent(
                event: .lifecycle,
                taskID: taskID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                lifecycle: value,
                toolName: toolName
            ))
        }

        XCTAssertEqual(viewModel.taskAgentState(task), .none)

        XCTAssertEqual(lifecycle("needs-input", toolName: "Bash").status, "applied")
        XCTAssertEqual(viewModel.taskAgentState(viewModel.tasks.first { $0.id == taskID }!), .needsInput)
        XCTAssertFalse(viewModel.taskIsRunning(viewModel.tasks.first { $0.id == taskID }!))

        XCTAssertEqual(lifecycle("running", toolName: "Bash").status, "applied")
        XCTAssertTrue(viewModel.taskIsRunning(viewModel.tasks.first { $0.id == taskID }!))
        XCTAssertEqual(viewModel.taskAgentState(viewModel.tasks.first { $0.id == taskID }!), .running)

        XCTAssertEqual(lifecycle("idle").status, "applied")
        XCTAssertFalse(viewModel.taskIsRunning(viewModel.tasks.first { $0.id == taskID }!))
        XCTAssertEqual(viewModel.taskAgentState(viewModel.tasks.first { $0.id == taskID }!), .idle)

        // Working state is runtime-only: it must never touch the persisted surface.
        XCTAssertNil(surface(viewModel, taskID, surfaceID).resumeBinding)
    }

    func testApplySessionEndClearsRunningFlag() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        let task = viewModel.tasks.first { $0.id == taskID }!
        let workspaceID = task.workspace.id
        let surfaceID = task.workspace.surfaces[0].id

        _ = viewModel.applyReportedSessionCapture(
            SessionReportEvent(
                event: .sessionStart,
                taskID: taskID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                agentName: "codex",
                sessionID: "sess-123"
            )
        )

        let result = viewModel.applyReportedSessionCapture(
            SessionReportEvent(
                event: .sessionEnd,
                taskID: taskID,
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        )

        XCTAssertEqual(result.status, "applied")
        XCTAssertEqual(surface(viewModel, taskID, surfaceID).resumeBinding?.wasRunning, false)
    }
}
