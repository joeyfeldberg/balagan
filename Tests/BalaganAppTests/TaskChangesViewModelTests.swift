import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// The Changes pane's view-model side: toggling, and loading a task's diff from its checkout. The
/// parser and git loader are covered in `GitDiffTests` (Core).
final class TaskChangesViewModelTests: XCTestCase {
    private var repo: String!

    override func setUpWithError() throws {
        repo = NSTemporaryDirectory() + "vm-changes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@e.com"], ["config", "user.name", "T"]] {
            try git(args)
        }
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "base"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        vm.synchronousGitReads = true
        // Point the first task's project at the scratch repo, working on main (no worktree).
        let projectID = vm.tasks[0].projectID
        vm.projects[vm.projects.firstIndex { $0.id == projectID }!].repoPath = repo
        vm.tasks[0].branchOrWorktree = nil
        vm.tasks[0].repoPathOverride = nil
        return vm
    }

    func testChangesAndReaderModeAreExclusive() {
        let vm = makeViewModel()
        vm.toggleChangesView()
        XCTAssertFalse(vm.showingChangesView, "no task open → nothing to review")

        vm.select(task: vm.tasks[0])
        vm.toggleReaderMode()
        vm.toggleChangesView()
        XCTAssertTrue(vm.showingChangesView)
        XCTAssertFalse(vm.showingReaderMode)

        vm.toggleReaderMode()
        XCTAssertTrue(vm.showingReaderMode)
        XCTAssertFalse(vm.showingChangesView)
    }

    func testRefreshLoadsTheTasksChanges() throws {
        let vm = makeViewModel()
        try "a\nb\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)

        vm.refreshTaskChanges(taskID: vm.tasks[0].id)
        guard case .loaded(let changes) = vm.taskChanges[vm.tasks[0].id] else {
            return XCTFail("expected loaded changes, got \(String(describing: vm.taskChanges[vm.tasks[0].id]))")
        }
        XCTAssertEqual(changes.files.map(\.path), ["a.txt"])
        XCTAssertEqual(changes.additions, 1)
        XCTAssertTrue(vm.taskChangesRefreshing.isEmpty)
    }

    func testAgentStoppingRefreshesOnlyTheVisibleTask() throws {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        vm.select(task: task)
        vm.toggleChangesView()
        vm.refreshTaskChanges(taskID: task.id)
        guard case .loaded(let before) = vm.taskChanges[task.id] else { return XCTFail("not loaded") }
        XCTAssertTrue(before.files.isEmpty)

        try "fresh\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
        let surfaceID = task.workspace.surfaces[0].id
        vm.setSurfaceLifecycle(.running, taskID: task.id, surfaceID: surfaceID)
        vm.setSurfaceLifecycle(.idle, taskID: task.id, surfaceID: surfaceID)

        guard case .loaded(let after) = vm.taskChanges[task.id] else { return XCTFail("not loaded") }
        XCTAssertEqual(after.files.map(\.path), ["new.txt"])
    }

    func testNotARepositoryIsAFailureState() {
        let vm = makeViewModel()
        let plain = NSTemporaryDirectory() + "plain-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        vm.tasks[0].repoPathOverride = plain

        vm.refreshTaskChanges(taskID: vm.tasks[0].id)
        guard case .failed = vm.taskChanges[vm.tasks[0].id] else { return XCTFail("expected failure") }
    }
}
