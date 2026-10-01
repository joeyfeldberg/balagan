import XCTest
@testable import BalaganCore

final class BoardStateMutationTests: XCTestCase {
    func testDeleteProjectRemovesProjectTasksAndWorkspaces() throws {
        var board = BalaganFixtures.boardState()

        let removed = try board.deleteProject(id: "balagan")

        XCTAssertEqual(removed.id, "balagan")
        XCTAssertNil(board.project(id: "balagan"))
        XCTAssertNil(board.task(id: "build-board"))
        XCTAssertNil(board.task(id: "resume-codex"))
        XCTAssertNil(board.workspace(forTaskID: "build-board"))
        XCTAssertNil(board.workspace(forTaskID: "resume-codex"))
        XCTAssertNotNil(board.project(id: "docs"))
        XCTAssertNotNil(board.task(id: "write-docs"))
    }

    func testMoveTaskByIDUpdatesStatusAndTimestamp() throws {
        let movedAt = Date(timeIntervalSince1970: 1_700_000_900)
        var board = BalaganFixtures.boardState()

        try board.moveTask(id: "build-board", to: .doing, at: movedAt)

        XCTAssertEqual(board.task(id: "build-board")?.status, .doing)
        XCTAssertEqual(board.task(id: "build-board")?.updatedAt, movedAt)
        XCTAssertEqual(board.task(id: "resume-codex")?.status, .doing)
    }

    func testDeleteTaskRemovesTaskAndItsWorkspace() throws {
        var board = BalaganFixtures.boardState()

        let removed = try board.deleteTask(id: "build-board")

        XCTAssertEqual(removed.id, "build-board")
        XCTAssertNil(board.task(id: "build-board"))
        XCTAssertNil(board.workspace(forTaskID: "build-board"))
        XCTAssertNotNil(board.task(id: "resume-codex"))
    }

    func testDeleteSurfaceFromTaskAllowsLastSurfaceToLeaveEmptyWorkspace() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_001_200)
        var board = BalaganFixtures.boardState()

        let removed = try board.deleteSurface(
            id: "surface-terminal",
            fromTaskID: "build-board",
            at: updatedAt
        )

        let task = try XCTUnwrap(board.task(id: "build-board"))
        let workspace = try XCTUnwrap(board.workspace(forTaskID: "build-board"))
        XCTAssertEqual(removed.id, "surface-terminal")
        XCTAssertEqual(task.workspace.surfaces, [])
        XCTAssertNil(task.workspace.selectedSurfaceID)
        XCTAssertEqual(task.workspace.layout, .tabs([]))
        XCTAssertEqual(task.updatedAt, updatedAt)
        XCTAssertEqual(workspace, task.workspace)
    }

    func testDeleteSelectedSurfaceSelectsFirstRemainingSurface() throws {
        let primary = BalaganFixtures.surface(id: "primary", title: "Primary")
        let secondary = BalaganFixtures.surface(id: "secondary", title: "Secondary")
        var workspace = BalaganFixtures.workspace(
            selectedSurfaceID: secondary.id,
            surfaces: [primary, secondary]
        )

        let removed = try workspace.deleteSurface(id: secondary.id)

        XCTAssertEqual(removed, secondary)
        XCTAssertEqual(workspace.surfaces, [primary])
        XCTAssertEqual(workspace.selectedSurfaceID, primary.id)
        XCTAssertEqual(workspace.layout, .tabs([.surface(primary.id)]))
    }

    func testDeleteSelectedSplitSurfaceCollapsesToSiblingSurface() throws {
        let primary = BalaganFixtures.surface(id: "primary", title: "Primary")
        let secondary = BalaganFixtures.surface(id: "secondary", title: "Secondary")
        var workspace = BalaganFixtures.workspace(
            layout: .split(axis: .horizontal, children: [.surface(primary.id), .surface(secondary.id)]),
            selectedSurfaceID: secondary.id,
            surfaces: [primary, secondary]
        )

        let removed = try workspace.deleteSurface(id: secondary.id)

        XCTAssertEqual(removed, secondary)
        XCTAssertEqual(workspace.surfaces, [primary])
        XCTAssertEqual(workspace.selectedSurfaceID, primary.id)
        XCTAssertEqual(workspace.layout, .surface(primary.id))
    }

    func testDeleteSurfaceFromNestedSplitPreservesRemainingSplitSelection() throws {
        let primary = BalaganFixtures.surface(id: "primary", title: "Primary")
        let secondary = BalaganFixtures.surface(id: "secondary", title: "Secondary")
        let tertiary = BalaganFixtures.surface(id: "tertiary", title: "Tertiary")
        var workspace = BalaganFixtures.workspace(
            layout: .split(
                axis: .horizontal,
                children: [
                    .surface(primary.id),
                    .split(axis: .vertical, children: [.surface(secondary.id), .surface(tertiary.id)]),
                ]
            ),
            selectedSurfaceID: tertiary.id,
            surfaces: [primary, secondary, tertiary]
        )

        let removed = try workspace.deleteSurface(id: secondary.id)

        XCTAssertEqual(removed, secondary)
        XCTAssertEqual(workspace.surfaces, [primary, tertiary])
        XCTAssertEqual(workspace.selectedSurfaceID, tertiary.id)
        XCTAssertEqual(workspace.layout, .split(axis: .horizontal, children: [.surface(primary.id), .surface(tertiary.id)]))
    }

    func testDeleteWorkspaceRemovesTopLevelWorkspaceAndLeavesTaskWithEmptyWorkspace() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_001_800)
        var board = BalaganFixtures.boardState()

        let removed = try board.deleteWorkspace(id: "workspace-build-board", at: updatedAt)

        let task = try XCTUnwrap(board.task(id: "build-board"))
        let otherTask = try XCTUnwrap(board.task(id: "resume-codex"))
        XCTAssertEqual(removed.id, "workspace-build-board")
        XCTAssertNil(board.workspace(id: "workspace-build-board"))
        XCTAssertEqual(task.workspace.id, "workspace-build-board")
        XCTAssertEqual(task.workspace.taskID, task.id)
        XCTAssertEqual(task.workspace.surfaces, [])
        XCTAssertNil(task.workspace.selectedSurfaceID)
        XCTAssertEqual(task.workspace.layout, .tabs([]))
        XCTAssertEqual(task.updatedAt, updatedAt)
        XCTAssertEqual(otherTask.workspace.taskID, otherTask.id)
    }

    func testMissingIDsThrowFocusedMutationErrors() {
        var board = BalaganFixtures.boardState()

        XCTAssertThrowsError(try board.moveTask(id: "missing", to: .done, at: BalaganFixtures.laterDate)) { error in
            XCTAssertEqual(error as? BoardStateMutationError, .taskNotFound("missing"))
        }

        XCTAssertThrowsError(try board.deleteProject(id: "missing-project")) { error in
            XCTAssertEqual(error as? BoardStateMutationError, .projectNotFound("missing-project"))
        }

        XCTAssertThrowsError(try board.deleteWorkspace(id: "missing-workspace")) { error in
            XCTAssertEqual(error as? BoardStateMutationError, .workspaceNotFound("missing-workspace"))
        }

        XCTAssertThrowsError(try board.deleteSurface(id: "missing-surface", fromTaskID: "build-board", at: BalaganFixtures.laterDate)) { error in
            XCTAssertEqual(error as? BoardStateMutationError, .surfaceNotFound("missing-surface"))
        }
    }
}
