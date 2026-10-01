import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Area (c): task CRUD in `BoardCRUD` — creating from a draft yields a task with the draft's defaults
/// and a main surface, unknown projects are rejected, and archive/restore round-trips through the
/// board/archived accessors. No `worktreeResolver` is injected, so no git runs.
final class BoardTaskCRUDTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    func testCreateTaskFromDraftAppendsTaskWithDefaults() throws {
        let viewModel = makeViewModel()
        var draft = TaskFormDraft.create(projectID: "balagan")
        draft.title = "New feature"
        draft.summary = "Do the thing"
        draft.status = .doing
        draft.priority = .high
        draft.tagsText = "alpha, beta"

        let created = try XCTUnwrap(viewModel.createTask(from: draft))

        XCTAssertEqual(created.title, "New feature")
        XCTAssertEqual(created.notes, "Do the thing")
        XCTAssertEqual(created.status, .doing)
        XCTAssertEqual(created.priority, .high)
        XCTAssertEqual(created.tags, ["alpha", "beta"])
        XCTAssertEqual(created.projectID, "balagan")
        XCTAssertEqual(created.workspace.surfaces.count, 1)
        XCTAssertEqual(created.workspace.selectedSurfaceID, created.workspace.surfaces.first?.id)
        XCTAssertTrue(viewModel.boardTasks.contains { $0.id == created.id })
        XCTAssertEqual(viewModel.selectedProjectID, "balagan")
    }

    func testCreateTaskReturnsNilForUnknownProject() {
        let viewModel = makeViewModel()
        var draft = TaskFormDraft.create(projectID: "does-not-exist")
        draft.title = "Orphan"

        XCTAssertNil(viewModel.createTask(from: draft))
    }

    func testArchiveAndRestoreRoundTrip() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        viewModel.select(task: viewModel.tasks.first { $0.id == taskID }!)

        viewModel.archiveTask(id: taskID, at: Date(timeIntervalSince1970: 3_000))

        XCTAssertFalse(viewModel.boardTasks.contains { $0.id == taskID })
        XCTAssertTrue(viewModel.archivedTasks.contains { $0.id == taskID })
        // Archiving the open task returns to the board.
        XCTAssertNil(viewModel.selectedTaskID)

        viewModel.unarchiveTask(id: taskID)

        XCTAssertTrue(viewModel.boardTasks.contains { $0.id == taskID })
        XCTAssertFalse(viewModel.archivedTasks.contains { $0.id == taskID })
    }
}
