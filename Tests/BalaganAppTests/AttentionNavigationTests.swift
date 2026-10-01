import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// "Next agent needing you" and the sidebar's task list, through the real view-model state. The pure
/// ordering is covered in `AgentAttentionQueueTests` / `SidebarTaskListTests` (Core).
final class AttentionNavigationTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        return vm
    }

    private func surface(_ vm: BoardViewModel, _ index: Int) -> (taskID: String, surfaceID: String) {
        (vm.tasks[index].id, vm.tasks[index].workspace.surfaces[0].id)
    }

    func testJumpVisitsTheOldestWaitingAgentThenTheNext() {
        let vm = makeViewModel()
        let first = surface(vm, 0)
        let second = surface(vm, 1)
        vm.setSurfaceLifecycle(.needsInput, taskID: second.taskID, surfaceID: second.surfaceID)
        vm.setSurfaceLifecycle(.needsInput, taskID: first.taskID, surfaceID: first.surfaceID)
        // Make the second task the longest-waiting one.
        vm.surfaceLifecycleSince[vm.hostKey(second.taskID, second.surfaceID)] = Date().addingTimeInterval(-600)

        XCTAssertTrue(vm.jumpToNextAgentNeedingYou())
        XCTAssertEqual(vm.selectedTaskID, second.taskID)
        XCTAssertEqual(vm.selectedSurfaceID, second.surfaceID)

        XCTAssertTrue(vm.jumpToNextAgentNeedingYou())
        XCTAssertEqual(vm.selectedTaskID, first.taskID)
    }

    func testJumpReachesAFinishedAgentAndReportsWhenThereIsNothing() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.jumpToNextAgentNeedingYou(), "nothing needs you → caller beeps")

        let target = surface(vm, 2)
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.idle, taskID: target.taskID, surfaceID: target.surfaceID)   // finished off-screen
        XCTAssertEqual(vm.agentsNeedingYouCount, 1)

        XCTAssertTrue(vm.jumpToNextAgentNeedingYou())
        XCTAssertEqual(vm.selectedTaskID, target.taskID)
        // Opening it cleared the "finished, unseen" flag, so the queue is now empty.
        XCTAssertEqual(vm.agentsNeedingYouCount, 0)
    }

    func testSleptTasksAreNotInTheQueue() {
        let vm = makeViewModel()
        let target = surface(vm, 0)
        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.hibernatedTaskIDs.insert(target.taskID)
        XCTAssertEqual(vm.agentsNeedingYouCount, 0)
    }

    func testSidebarKeepsADoneTaskOnlyWhileItNeedsYouOrIsOpen() {
        let vm = makeViewModel()
        vm.tasks[0].status = .done
        let project = vm.project(for: vm.tasks[0].projectID)!
        XCTAssertFalse(vm.sidebarTasks(for: project).contains { $0.id == vm.tasks[0].id })

        let target = surface(vm, 0)
        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        XCTAssertTrue(vm.sidebarTasks(for: project).contains { $0.id == vm.tasks[0].id })
    }

    func testCollapsingAProjectPersistsOnTheProject() {
        let vm = makeViewModel()
        let projectID = vm.projects[0].id
        vm.toggleSidebarCollapsed(projectID: projectID)
        XCTAssertTrue(vm.projects[0].sidebarCollapsed)

        let data = try! JSONEncoder().encode(vm.projects[0])
        XCTAssertTrue(try JSONDecoder().decode(Project.self, from: data).sidebarCollapsed)
        // Boards saved before the flag existed decode expanded.
        let legacy = #"{"id":"p","name":"P","repoPath":"/r"}"#
        XCTAssertFalse(try JSONDecoder().decode(Project.self, from: Data(legacy.utf8)).sidebarCollapsed)
    }
}
