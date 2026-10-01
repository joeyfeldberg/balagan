import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Which tasks read as "not running": anything without a live terminal, once live terminals are
/// being tracked (the real app); only explicitly slept tasks when they aren't (`--ui-test-mode`).
final class DormancyTests: XCTestCase {
    private func makeViewModel(tracking: Bool = true) -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        vm.tracksLiveTerminals = tracking
        return vm
    }

    func testAfterARestartEveryTaskIsDormantUntilItHasALiveTerminal() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.tasks.allSatisfy { vm.taskIsDormant($0) })
        XCTAssertEqual(vm.dormantReason(vm.tasks[0]), "Not started since Balagan opened")

        vm.liveTaskIDs = [vm.tasks[0].id]
        XCTAssertFalse(vm.taskIsDormant(vm.tasks[0]))
        XCTAssertTrue(vm.taskIsDormant(vm.tasks[1]))
    }

    func testSleepReasonsWin() {
        let vm = makeViewModel()
        vm.hibernatedTaskIDs.insert(vm.tasks[0].id)
        XCTAssertEqual(vm.dormantReason(vm.tasks[0]), "Put to sleep")
        vm.autoSleepReasons[vm.tasks[0].id] = "Slept after 31m idle"
        XCTAssertEqual(vm.dormantReason(vm.tasks[0]), "Slept after 31m idle")
    }

    func testWithoutTrackingOnlyAnExplicitSleepIsDormant() {
        let vm = makeViewModel(tracking: false)
        XCTAssertFalse(vm.taskIsDormant(vm.tasks[0]))
        vm.hibernatedTaskIDs.insert(vm.tasks[0].id)
        XCTAssertTrue(vm.taskIsDormant(vm.tasks[0]))
    }

    func testWakingInTheBackgroundUsesTheWakerAndClearsSleep() {
        let vm = makeViewModel()
        var woken: [TaskItem.ID] = []
        vm.backgroundTaskWaker = { woken.append($0) }
        let task = vm.tasks[0]
        vm.hibernatedTaskIDs.insert(task.id)
        vm.autoSleepReasons[task.id] = "Slept after 31m idle"

        vm.wakeInBackground(taskID: task.id)
        XCTAssertEqual(woken, [task.id])
        XCTAssertFalse(vm.hibernatedTaskIDs.contains(task.id))
        XCTAssertNil(vm.autoSleepReasons[task.id])

        // A live task isn't woken again.
        vm.liveTaskIDs = [task.id]
        vm.wakeInBackground(taskID: task.id)
        XCTAssertEqual(woken, [task.id])
    }
}
