import XCTest
@testable import BalaganApp
@testable import BalaganCore

final class BoardAgentProcessTests: XCTestCase {
    private let taskID = "board-shell"

    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    private func binding(for surface: Surface, pid: Int32?) -> ResumeBinding {
        ResumeBinding(id: "b", surfaceID: surface.id, kind: .agent, agentName: "claude", command: "claude", pid: pid, updatedAt: Date())
    }

    func testPrefersTheSessionBindingsPid() {
        let viewModel = makeViewModel()
        var surface = viewModel.task(for: taskID)!.workspace.surfaces[0]
        surface.resumeBinding = binding(for: surface, pid: 111)
        viewModel.runningAgents[viewModel.hostKey(taskID, surface.id)] = RunningAgent(name: "claude", pid: 222)

        XCTAssertEqual(viewModel.agentPID(taskID: taskID, surface: surface), 111)
    }

    /// An agent typed at a prompt that hasn't reported a session yet still gets stopped on Sleep / Restart.
    func testFallsBackToTheRunningAgentBeforeASessionIsReported() {
        let viewModel = makeViewModel()
        var surface = viewModel.task(for: taskID)!.workspace.surfaces[0]
        surface.resumeBinding = nil
        XCTAssertNil(viewModel.agentPID(taskID: taskID, surface: surface))

        viewModel.runningAgents[viewModel.hostKey(taskID, surface.id)] = RunningAgent(name: "opencode", pid: 222)
        XCTAssertEqual(viewModel.agentPID(taskID: taskID, surface: surface), 222)
    }

    func testIgnoresNonPositivePids() {
        let viewModel = makeViewModel()
        var surface = viewModel.task(for: taskID)!.workspace.surfaces[0]
        surface.resumeBinding = binding(for: surface, pid: 0)
        XCTAssertNil(viewModel.agentPID(taskID: taskID, surface: surface))
    }
}
