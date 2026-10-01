import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// How the view model describes a task to `AutoSleepPlanner` (Core, where the rules are tested).
/// Performing the sleep needs live libghostty terminals, which unit tests don't have.
@MainActor
final class AutoSleepViewModelTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        return vm
    }

    private func makeAgentTab(_ vm: BoardViewModel, taskIndex: Int = 0) -> Surface.ID {
        let surfaceID = vm.tasks[taskIndex].workspace.surfaces[0].id
        vm.tasks[taskIndex].workspace.surfaces[0].resumeBinding = ResumeBinding(
            id: "binding",
            surfaceID: surfaceID,
            kind: .agent,
            agentName: "claude",
            sessionID: "session-1",
            command: "claude --resume session-1"
        )
        return surfaceID
    }

    func testAnAgentTabIsIdleUnlessItsAgentIsWorkingOrWaiting() {
        let vm = makeViewModel()
        let surfaceID = makeAgentTab(vm)
        let taskID = vm.tasks[0].id
        let now = Date()

        // A resumed agent that hasn't reported anything yet is resumable, so it counts as idle.
        XCTAssertEqual(vm.autoSleepInput(for: vm.tasks[0], now: now).surfaces, [.agentIdle])

        vm.setSurfaceLifecycle(.running, taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.autoSleepInput(for: vm.tasks[0], now: now).surfaces, [.agentActive])
        vm.setSurfaceLifecycle(.needsInput, taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.autoSleepInput(for: vm.tasks[0], now: now).surfaces, [.agentActive])
        vm.setSurfaceLifecycle(.idle, taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.autoSleepInput(for: vm.tasks[0], now: now).surfaces, [.agentIdle])
    }

    func testAPlainShellWithoutALiveTerminalIsIdle() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.autoSleepInput(for: vm.tasks[0], now: Date()).surfaces, [.shellIdle])
    }

    func testIdleClockStartsAtFirstSightingAndFollowsActivity() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        let first = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(vm.autoSleepInput(for: task, now: first).lastActiveAt, first)
        // A later pass doesn't move the clock on its own.
        XCTAssertEqual(vm.autoSleepInput(for: task, now: first.addingTimeInterval(600)).lastActiveAt, first)

        let visited = first.addingTimeInterval(120)
        vm.noteTaskActivity(task.id, at: visited)
        XCTAssertEqual(vm.autoSleepInput(for: task, now: first.addingTimeInterval(600)).lastActiveAt, visited)

        // An agent changing state is activity too.
        vm.setSurfaceLifecycle(.idle, taskID: task.id, surfaceID: task.workspace.surfaces[0].id)
        XCTAssertGreaterThan(vm.autoSleepInput(for: task, now: Date()).lastActiveAt, visited)
    }

    func testOnScreenAndUnseenAreReported() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        vm.select(task: task)
        XCTAssertTrue(vm.autoSleepInput(for: task, now: Date()).isOnScreen)

        let other = vm.tasks[1]
        vm.flagSurfaceNeedsAttention(taskID: other.id, surfaceID: other.workspace.surfaces[0].id)
        XCTAssertTrue(vm.autoSleepInput(for: other, now: Date()).hasUnseenResult)
    }

    func testNothingSleepsWithoutLiveTerminals() {
        let vm = makeViewModel()
        _ = makeAgentTab(vm)
        XCTAssertEqual(vm.runAutoSleep(underMemoryPressure: true, now: Date().addingTimeInterval(86_400)), [])
    }

    func testWakingClearsTheReason() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        vm.hibernatedTaskIDs.insert(task.id)
        vm.autoSleepReasons[task.id] = "Slept after 30m idle"
        vm.select(task: task)
        XCTAssertNil(vm.autoSleepReasons[task.id])
        XCTAssertFalse(vm.hibernatedTaskIDs.contains(task.id))
    }

    func testSettingsLabels() {
        XCTAssertEqual(SettingsSheet.autoSleepLabel(0), "Never")
        XCTAssertEqual(SettingsSheet.autoSleepLabel(30), "30 minutes")
        XCTAssertEqual(SettingsSheet.autoSleepLabel(60), "1 hour")
        XCTAssertEqual(SettingsSheet.autoSleepLabel(120), "2 hours")
    }
}
