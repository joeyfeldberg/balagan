import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Area (b): surface CRUD selection/reindex math in `BoardSurfaceLifecycle` — create moves selection,
/// split produces the right layout shape, delete falls to the documented replacement rule.
final class BoardSurfaceLifecycleTests: XCTestCase {
    /// The multi-project fixture's "board-shell" task: one surface ("agent"), layout `.tabs([.surface])`.
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    private func workspace(_ viewModel: BoardViewModel, _ taskID: TaskItem.ID) -> Workspace {
        viewModel.tasks.first { $0.id == taskID }!.workspace
    }

    func testCreateSurfaceMovesSelectionToNewSurface() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        viewModel.select(task: viewModel.tasks.first { $0.id == taskID }!)

        viewModel.createSurface(taskID: taskID, title: "second", cwd: "/tmp", startupCommand: nil)

        let space = workspace(viewModel, taskID)
        XCTAssertEqual(space.surfaces.count, 2)
        let newSurfaceID = space.surfaces.last!.id
        XCTAssertEqual(space.selectedSurfaceID, newSurfaceID)
        // The task is the selected one, so the view-model-level selection follows.
        XCTAssertEqual(viewModel.selectedSurfaceID, newSurfaceID)
    }

    func testSplitSurfaceProducesSplitLayoutInsideTab() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"

        viewModel.splitSurface(taskID: taskID, axis: .horizontal)

        let space = workspace(viewModel, taskID)
        XCTAssertEqual(space.surfaces.count, 2)
        // Canonical Ghostty shape: root .tabs, the single tab is a split of two panes.
        XCTAssertEqual(space.layout.tabContents.count, 1)
        guard case .split(let axis, let children) = space.layout.tabContents[0] else {
            return XCTFail("expected the tab to hold a split, got \(space.layout.tabContents[0])")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(space.selectedSurfaceID, space.surfaces.last!.id)
    }

    func testDeleteSelectedSurfaceFallsToTrailingNeighbor() {
        let viewModel = makeViewModel()
        let taskID = "board-shell"
        viewModel.select(task: viewModel.tasks.first { $0.id == taskID }!)
        viewModel.createSurface(taskID: taskID, title: "b", cwd: "/tmp", startupCommand: nil)
        viewModel.createSurface(taskID: taskID, title: "c", cwd: "/tmp", startupCommand: nil)

        let ordered = workspace(viewModel, taskID).layout.surfaceIDs()
        XCTAssertEqual(ordered.count, 3)
        let middle = ordered[1]
        let trailing = ordered[2]
        viewModel.select(surfaceID: middle, forTaskID: taskID)

        viewModel.deleteSurface(taskID: taskID, surfaceID: middle)

        let space = workspace(viewModel, taskID)
        XCTAssertEqual(space.surfaces.count, 2)
        XCTAssertFalse(space.surfaces.contains { $0.id == middle })
        // Replacement rule: prefer the trailing neighbor of the deleted surface.
        XCTAssertEqual(space.selectedSurfaceID, trailing)
        XCTAssertEqual(viewModel.selectedSurfaceID, trailing)
    }

    /// The pure replacement-rule helper directly: trailing neighbor first, then the leading one, then
    /// any available surface if the deleted id wasn't in the previous order.
    func testReplacementSurfaceIDPrefersTrailingThenLeading() {
        let viewModel = makeViewModel()

        XCTAssertEqual(
            viewModel.replacementSurfaceID(
                afterDeleting: "b",
                previousOrderedSurfaceIDs: ["a", "b", "c"],
                availableSurfaceIDs: ["a", "c"]
            ),
            "c"
        )
        XCTAssertEqual(
            viewModel.replacementSurfaceID(
                afterDeleting: "c",
                previousOrderedSurfaceIDs: ["a", "b", "c"],
                availableSurfaceIDs: ["a", "b"]
            ),
            "b"
        )
        XCTAssertEqual(
            viewModel.replacementSurfaceID(
                afterDeleting: "unknown",
                previousOrderedSurfaceIDs: ["a", "b"],
                availableSurfaceIDs: ["a", "b"]
            ),
            "a"
        )
    }
}
