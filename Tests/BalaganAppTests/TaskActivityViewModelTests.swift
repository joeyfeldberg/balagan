import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// The card's live activity line, driven through the real `setSurfaceLifecycle` funnel. The pure
/// rules (labels, summary, preview, primary surface) are covered in `TaskActivityTests` (Core).
final class TaskActivityViewModelTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        return vm
    }

    func testNoActivityForATaskWithoutAnAgent() {
        let vm = makeViewModel()
        XCTAssertNil(vm.taskActivity(vm.tasks[0]))
    }

    func testLifecycleChangeStampsSinceAndClearsIt() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        let key = vm.hostKey(taskID, surfaceID)

        let before = Date()
        vm.setSurfaceLifecycle(.running, taskID: taskID, surfaceID: surfaceID)
        let since = try? XCTUnwrap(vm.surfaceLifecycleSince[key])
        XCTAssertGreaterThanOrEqual(since ?? .distantPast, before)

        // Re-reporting the same state must not restart the clock.
        vm.setSurfaceLifecycle(.running, taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.surfaceLifecycleSince[key], since)

        XCTAssertEqual(vm.taskActivity(vm.tasks[0])?.lifecycle, .running)

        vm.setSurfaceLifecycle(nil as AgentLifecycle?, taskID: taskID, surfaceID: surfaceID)
        XCTAssertNil(vm.surfaceLifecycleSince[key])
    }

    func testActivityDescribesTheWaitingTabOfAMultiTabTask() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        var second = vm.tasks[0].workspace.surfaces[0]
        second.id = "second-agent"
        second.title = "✳ Answer the migration question"
        vm.tasks[0].workspace.surfaces.append(second)
        let firstID = vm.tasks[0].workspace.surfaces[0].id

        vm.setSurfaceLifecycle(.running, taskID: taskID, surfaceID: firstID)
        vm.setSurfaceLifecycle(.needsInput, taskID: taskID, surfaceID: "second-agent")
        vm.surfaceLastResponses[vm.hostKey(taskID, "second-agent")] = "Migrate now or later?"

        let activity = vm.taskActivity(vm.tasks[0])
        XCTAssertEqual(activity?.lifecycle, .needsInput)
        XCTAssertEqual(activity?.summary, "Answer the migration question")
        XCTAssertEqual(activity?.visibleLastResponse, "Migrate now or later?")
    }

    func testSleptTaskHasNoActivity() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        vm.setSurfaceLifecycle(.idle, taskID: task.id, surfaceID: task.workspace.surfaces[0].id)
        vm.hibernatedTaskIDs.insert(task.id)
        XCTAssertNil(vm.taskActivity(vm.tasks[0]))
    }
}
