import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// An agent typed at a Balagan prompt reports its start through the wrapper — often before it has a
/// session id. The tab must become an agent tab immediately, and bind when the session arrives.
final class TypedAgentTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        vm.transcriptPreviewsEnabled = false
        return vm
    }

    private func start(_ vm: BoardViewModel, agent: String, session: String?, pid: Int32? = nil) -> SessionReportApplyResult {
        let task = vm.tasks[0]
        return vm.applyReportedSessionCapture(SessionReportEvent(
            event: .sessionStart,
            taskID: task.id,
            workspaceID: task.workspace.id,
            surfaceID: task.workspace.surfaces[0].id,
            agentName: agent,
            sessionID: session,
            pid: pid,
            command: session.flatMap { AgentProfiles.named(agent)?.resumeCommand(sessionID: $0) }
        ))
    }

    func testAStartWithoutASessionMakesItAnAgentTab() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        let surfaceID = task.workspace.surfaces[0].id
        XCTAssertFalse(vm.surfaceIsAgentTerminal(taskID: task.id, surfaceID: surfaceID))

        XCTAssertEqual(start(vm, agent: "opencode", session: nil).status, "applied")
        XCTAssertTrue(vm.surfaceIsAgentTerminal(taskID: task.id, surfaceID: surfaceID))
        XCTAssertNil(vm.tasks[0].workspace.surfaces[0].resumeBinding, "nothing to resume yet")

        // The plugin reports the session: now it's a resumable agent tab.
        _ = start(vm, agent: "opencode", session: "ses_1")
        let binding = vm.tasks[0].workspace.surfaces[0].resumeBinding
        XCTAssertEqual(binding?.agentName, "opencode")
        XCTAssertEqual(binding?.command, "opencode --session ses_1")
        XCTAssertEqual(vm.tasks[0].workspace.surfaces[0].agentKind, .opencode)
        XCTAssertNil(vm.runningAgents[vm.hostKey(task.id, surfaceID)])
    }

    func testAnAgentThatQuitsLeavesThePlainShell() {
        let vm = makeViewModel()
        let task = vm.tasks[0]
        let surfaceID = task.workspace.surfaces[0].id
        _ = start(vm, agent: "codex", session: nil, pid: 999_999)   // no such process
        vm.setSurfaceLifecycle(.running, taskID: task.id, surfaceID: surfaceID)

        vm.reconcileAgentLifecycles()
        XCTAssertNil(vm.runningAgents[vm.hostKey(task.id, surfaceID)])
        XCTAssertNil(vm.surfaceLifecycle[vm.hostKey(task.id, surfaceID)], "a dead agent isn't running")
        XCTAssertFalse(vm.surfaceIsAgentTerminal(taskID: task.id, surfaceID: surfaceID))
    }

    func testPiResumesThroughItsProfile() {
        let vm = makeViewModel()
        _ = start(vm, agent: "pi", session: "u-1")
        let surface = vm.tasks[0].workspace.surfaces[0]
        XCTAssertEqual(surface.agentKind, .pi)
        XCTAssertEqual(surface.resumePlan(taskID: vm.tasks[0].id)?.argv, ["pi", "--session-id", "u-1"])
    }
}
