import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// What a tab's exit does, through the real view-model path. Rules: `AgentExitPolicyTests` (Core).
final class AgentExitTests: XCTestCase {
    private var relaunched: [String] = []

    private func makeViewModel(agent: Bool = true, session: Bool = true) -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        vm.agentRelauncher = { [weak self] _, surfaceID in self?.relaunched.append(surfaceID) }
        if agent {
            let surfaceID = vm.tasks[0].workspace.surfaces[0].id
            vm.tasks[0].workspace.surfaces[0].resumeBinding = ResumeBinding(
                id: "b",
                surfaceID: surfaceID,
                kind: .agent,
                agentName: "codex",
                sessionID: session ? "s-1" : nil,
                command: "codex resume s-1"
            )
        }
        return vm
    }


    func testAPlainShellStillClosesItsTab() {
        let vm = makeViewModel(agent: false)
        let task = vm.tasks[0]
        XCTAssertEqual(vm.handleEndedProcess(taskID: task.id, surfaceID: task.workspace.surfaces[0].id), .closeTab)
        XCTAssertTrue(relaunched.isEmpty)
    }

    func testAnAgentThatQuitsRightAfterStartingIsResumedWithANotice() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        vm.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)

        XCTAssertEqual(vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID), .resumeAutomatically)
        XCTAssertEqual(relaunched, [surfaceID])
        XCTAssertEqual(vm.agentAutoResumeNotice?.key, vm.hostKey(taskID, surfaceID))
        XCTAssertTrue(vm.agentAutoResumeNotice?.text.hasPrefix("Codex exited right after starting") ?? false)
        XCTAssertNil(vm.endedAgent(taskID: taskID, surfaceID: surfaceID))
    }

    func testCrashOnStartStopsAfterTwoResumesAndOffersResume() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        for _ in 0..<2 {
            vm.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)
            vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID)
        }
        vm.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID), .offerResume)
        XCTAssertEqual(relaunched.count, 2)
        XCTAssertEqual(vm.endedAgent(taskID: taskID, surfaceID: surfaceID)?.gaveUpAutoResume, true)
    }

    func testALaterExitOffersResumeAndResumingClearsIt() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        vm.surfaceLaunchedAt[vm.hostKey(taskID, surfaceID)] = Date().addingTimeInterval(-3600)

        XCTAssertEqual(vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID), .offerResume)
        XCTAssertEqual(vm.endedAgent(taskID: taskID, surfaceID: surfaceID)?.offer, .resume)
        XCTAssertEqual(vm.endedAgent(taskID: taskID, surfaceID: surfaceID)?.agentName, "Codex")
        XCTAssertTrue(relaunched.isEmpty)

        vm.resumeEndedAgent(taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(relaunched, [surfaceID])
        XCTAssertNil(vm.endedAgent(taskID: taskID, surfaceID: surfaceID))
        // ⏎ in a tab that isn't offering anything does nothing.
        vm.resumeEndedAgent(taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(relaunched.count, 1)
    }

    func testAnAgentWithoutASessionOffersAStart() {
        let vm = makeViewModel(session: false)
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        vm.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)
        XCTAssertEqual(vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID), .offerRestart)
        XCTAssertEqual(vm.endedAgent(taskID: taskID, surfaceID: surfaceID)?.offer, .restart)
    }

    func testRelaunchingClearsTheExitedState() {
        let vm = makeViewModel()
        let taskID = vm.tasks[0].id
        let surfaceID = vm.tasks[0].workspace.surfaces[0].id
        vm.handleEndedProcess(taskID: taskID, surfaceID: surfaceID)
        XCTAssertNotNil(vm.endedAgent(taskID: taskID, surfaceID: surfaceID))
        vm.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)
        XCTAssertNil(vm.endedAgent(taskID: taskID, surfaceID: surfaceID))
    }
}
