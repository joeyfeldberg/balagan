import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Editing a task's workspace moves its terminals with it, and opening a task never starts a terminal
/// in a missing directory. The regression: created with a worktree, switched to "Work on main" before
/// the first open, then opened — the terminal kept the never-created worktree path, Ghostty fell back
/// to $HOME, and the project's worktree setup ran there.
final class TaskWorkspaceEditTests: XCTestCase {
    private var root: URL!
    private var repo: String { root.appendingPathComponent("repo").path }
    private var worktrees: String { root.appendingPathComponent("worktrees").path }
    private let setup = "uv sync"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewModel() -> BoardViewModel {
        let project = Project(id: "p", name: "p", repoPath: repo, worktreesDirectory: worktrees, setupCommands: setup)
        return BoardViewModel(projects: [project], tasks: [], selectedTaskID: nil)
    }

    private func createTask(_ viewModel: BoardViewModel, branch: String) throws -> TaskItem {
        var draft = TaskFormDraft.create(projectID: "p")
        draft.title = "docs"
        draft.branchOrWorktree = branch
        return try XCTUnwrap(viewModel.createTask(from: draft))
    }

    private func edit(_ viewModel: BoardViewModel, _ taskID: TaskItem.ID, branch: String) {
        var draft = TaskFormDraft.edit(viewModel.tasks.first { $0.id == taskID }!)
        draft.branchOrWorktree = branch
        viewModel.updateTask(from: draft)
    }

    private func surface(_ viewModel: BoardViewModel, _ taskID: TaskItem.ID) -> Surface {
        viewModel.tasks.first { $0.id == taskID }!.workspace.surfaces[0]
    }

    func testSwitchingAnUnopenedWorktreeTaskToMainMovesItsTerminalToTheMainCheckout() throws {
        let viewModel = makeViewModel()
        let task = try createTask(viewModel, branch: "docs")
        XCTAssertEqual(surface(viewModel, task.id).setupCommand, setup)
        XCTAssertNotEqual(surface(viewModel, task.id).cwd, repo)

        edit(viewModel, task.id, branch: "")

        let moved = surface(viewModel, task.id)
        XCTAssertEqual(moved.cwd, repo)
        XCTAssertNil(moved.setupCommand, "the main checkout never runs the worktree setup")
        XCTAssertEqual(moved.environment["BALAGAN_WORKTREE_PATH"], repo)
        XCTAssertEqual(moved.output, [Surface.pwdPlaceholderSeed, repo])
    }

    func testSwitchingAMainTaskToAWorktreeQueuesSetupForTheNewWorktree() throws {
        let viewModel = makeViewModel()
        let task = try createTask(viewModel, branch: "")
        XCTAssertEqual(surface(viewModel, task.id).cwd, repo)

        edit(viewModel, task.id, branch: "docs")

        let moved = surface(viewModel, task.id)
        XCTAssertNotEqual(moved.cwd, repo)
        XCTAssertTrue(moved.cwd.hasPrefix(worktrees))
        XCTAssertEqual(moved.setupCommand, setup)
        XCTAssertEqual(moved.environment["BALAGAN_WORKTREE_PATH"], moved.cwd)
    }

    func testOpeningATaskWhoseTerminalDirectoryIsMissingFallsBackToTheMainCheckout() throws {
        let viewModel = makeViewModel()
        let task = try createTask(viewModel, branch: "")
        let index = viewModel.tasks.firstIndex { $0.id == task.id }!
        // A board saved by the buggy build: no branch, but still pointed at a worktree that was never made.
        viewModel.tasks[index].workspace.surfaces[0].cwd = worktrees + "/docs"
        viewModel.tasks[index].workspace.surfaces[0].setupCommand = setup

        viewModel.repairMissingWorkingDirectories(taskID: task.id)

        XCTAssertEqual(surface(viewModel, task.id).cwd, repo)
        XCTAssertNil(surface(viewModel, task.id).setupCommand)
    }

    func testATerminalThatMovedElsewhereIsLeftAlone() throws {
        let viewModel = makeViewModel()
        let task = try createTask(viewModel, branch: "docs")
        let index = viewModel.tasks.firstIndex { $0.id == task.id }!
        let elsewhere = root.path
        viewModel.tasks[index].workspace.surfaces[0].cwd = elsewhere

        edit(viewModel, task.id, branch: "")
        viewModel.repairMissingWorkingDirectories(taskID: task.id)

        XCTAssertEqual(surface(viewModel, task.id).cwd, elsewhere)
    }
}
