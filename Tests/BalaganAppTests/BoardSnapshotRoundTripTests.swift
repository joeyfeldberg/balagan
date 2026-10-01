import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Area (a): the `BoardSnapshotMapping` round-trip — a view model → `BoardSnapshot` → view model
/// must preserve the board (projects/tasks/workspaces) and the persisted UI state.
///
/// Fixture surfaces carry no `startupCommand`, so the codex-recovery pass that runs in `init` is a
/// no-op (`.notNeeded`) and the round-trip is deterministic — no disk/env dependence.
final class BoardSnapshotRoundTripTests: XCTestCase {
    func testSnapshotRoundTripPreservesBoardAndUIState() {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let original = BoardViewModel(
            projects: seed.projects,
            tasks: seed.tasks,
            selectedTaskID: seed.tasks[0].id
        )
        // Exercise a few UI-state fields so the round-trip actually carries non-default values.
        original.updateUIScale(1.25)
        _ = original.increaseTerminalFontSize()

        let snapshot = original.makeSnapshot(savedAt: Date(timeIntervalSince1970: 1_000))
        let rebuilt = BoardViewModel(snapshot: snapshot, dataSource: "test")

        XCTAssertEqual(rebuilt.projects, original.projects)
        XCTAssertEqual(rebuilt.tasks, original.tasks)
        XCTAssertEqual(rebuilt.selectedProjectID, original.selectedProjectID)
        XCTAssertEqual(rebuilt.selectedTaskID, original.selectedTaskID)
        XCTAssertEqual(rebuilt.selectedWorkspaceID, original.selectedWorkspaceID)
        XCTAssertEqual(rebuilt.selectedSurfaceID, original.selectedSurfaceID)
        XCTAssertEqual(rebuilt.uiAppearance, original.uiAppearance)
        XCTAssertEqual(rebuilt.terminalAppearance, original.terminalAppearance)
        XCTAssertEqual(rebuilt.keyboardShortcuts, original.keyboardShortcuts)
    }

    func testSnapshotRoundTripPreservesResumeBindings() {
        let seed = BoardFixtures.seed(named: "resumable-task")
        let original = BoardViewModel(
            projects: seed.projects,
            tasks: seed.tasks,
            selectedTaskID: seed.selectedTaskID
        )

        let snapshot = original.makeSnapshot(savedAt: Date(timeIntervalSince1970: 2_000))
        let rebuilt = BoardViewModel(snapshot: snapshot, dataSource: "test")

        XCTAssertEqual(rebuilt.tasks, original.tasks)
        let agent = rebuilt.tasks.first?.workspace.surfaces.first { $0.id == "agent" }
        XCTAssertEqual(agent?.resumeBinding?.sessionID, "4f7e-session")
        XCTAssertEqual(agent?.resumeBinding?.kind, .agent)
    }
}
