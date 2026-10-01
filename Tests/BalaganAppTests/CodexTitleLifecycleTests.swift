import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Driver-level coverage for Codex agent working-state, which is derived entirely from the terminal
/// title (our wrapper installs no Codex hooks, so before this a Codex surface had *no* lifecycle at all
/// and every Codex task read `.idle` forever — and Codex is the default agent).
///
/// These drive the real path: classify a title exactly as the `SET_TITLE` callback does, hand it to the
/// view model, then run a reconcile tick.
final class CodexTitleLifecycleTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    /// Adds a tab launched through the wrapper for `agent`, returning its ids. No pid is recorded, so
    /// the reconciler treats the process as alive — the live-agent case.
    private func addAgentSurface(_ vm: BoardViewModel, _ agent: String) -> (taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let taskID = vm.tasks.first!.id
        vm.createSurface(taskID: taskID, title: "\(agent) tab", cwd: "/tmp/\(agent)",
                         startupCommand: "balagan-agent \(agent)")
        let surface = vm.tasks.first { $0.id == taskID }!.workspace.surfaces.last!
        XCTAssertEqual(surface.agentKind, AgentKind(rawValue: agent), "precondition: the surface reads as \(agent)")
        return (taskID, surface.id)
    }

    /// The `SET_TITLE` path: classify, then record. A title that says nothing (blank) is not reported,
    /// exactly as the callback skips it.
    private func setTitle(_ vm: BoardViewModel, _ ids: (taskID: TaskItem.ID, surfaceID: Surface.ID), _ title: String) {
        guard let signal = AgentTitleHeuristic.classify(title: title) else { return }
        vm.updateTitleSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, signal: signal)
    }

    private func lifecycle(
        _ vm: BoardViewModel,
        _ ids: (taskID: TaskItem.ID, surfaceID: Surface.ID)
    ) -> AgentLifecycle? {
        vm.surfaceLifecycle[vm.hostKey(ids.taskID, ids.surfaceID)]
    }

    func testCodexSpinnerTitleMakesTheSurfaceRunning() {
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        setTitle(vm, ids, "⠋ codex")
        vm.reconcileAgentLifecycles()

        XCTAssertEqual(lifecycle(vm, ids), .running)
        XCTAssertTrue(vm.taskIsRunning(vm.tasks.first { $0.id == ids.taskID }!),
                      "the card spinner must light up for a working Codex agent")
    }

    func testCodexActionRequiredTitleMakesTheSurfaceNeedsInput() {
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        setTitle(vm, ids, "Action Required · codex")
        vm.reconcileAgentLifecycles()

        XCTAssertEqual(lifecycle(vm, ids), .needsInput)
        XCTAssertEqual(vm.taskAgentState(vm.tasks.first { $0.id == ids.taskID }!), .needsInput,
                       "`balagan wait` must see a blocked Codex agent")
    }

    func testCodexFallsBackToIdleOnTheNextTickOnceThePlainTitleReturns() {
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        setTitle(vm, ids, "⠙ codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)

        setTitle(vm, ids, "codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .idle)
    }

    func testCodexNeedsInputClearsOnceTheTitleStopsSayingActionRequired() {
        // The answered-prompt case: nothing else can clear it, so the title must.
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        setTitle(vm, ids, "Action Required · codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput)

        setTitle(vm, ids, "codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .idle)

        // And an approval that resumes work goes straight back to running — no streak gate for Codex.
        setTitle(vm, ids, "Action Required · codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput)
        setTitle(vm, ids, "⠸ codex")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)
    }

    func testTitleFlickerBetweenTicksNeverFlapsTheState() {
        // The 2s tick is the debounce: only the title standing *at* the tick is read.
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        for frame in ["⠋", "⠙", "⠹", "⠸"] {
            setTitle(vm, ids, "\(frame) codex")
        }
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)
    }

    func testClaudeSurfaceIsNotPutIntoNeedsInputByItsTitle() {
        // Claude's needs-input is hook-only. A title merely containing the phrase (a tool name, a repo
        // called "action-required", an agent echoing the words) must not fake a permission prompt.
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "claude")

        setTitle(vm, ids, "Action Required · claude")
        vm.reconcileAgentLifecycles()
        XCTAssertNil(lifecycle(vm, ids), "no hook has spoken, and the title may not speak for Claude")

        // With a hook-set running it reads as a spinner-less title: demoted to idle, never needs-input.
        vm.setSurfaceLifecycle(.running, taskID: ids.taskID, surfaceID: ids.surfaceID)
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)

        setTitle(vm, ids, "Action Required · claude")
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .idle)
    }

    func testAHibernatedTaskIsSkipped() {
        let vm = makeViewModel()
        let ids = addAgentSurface(vm, "codex")

        setTitle(vm, ids, "⠋ codex")
        vm.hibernatedTaskIDs.insert(ids.taskID)
        vm.reconcileAgentLifecycles()

        XCTAssertNil(lifecycle(vm, ids), "a slept task's agents are terminated; a stale title can't revive one")
        XCTAssertEqual(vm.taskAgentState(vm.tasks.first { $0.id == ids.taskID }!), .asleep)
    }

    func testAPlainShellSurfaceIsUnaffected() {
        // No agent kind and no hook state ⇒ nothing to reconcile, even with a title.
        let vm = makeViewModel()
        let taskID = vm.tasks.first!.id
        vm.createSurface(taskID: taskID, title: "shell", cwd: "/tmp/shell", startupCommand: "zsh -l")
        let surfaceID = vm.tasks.first { $0.id == taskID }!.workspace.surfaces.last!.id
        let ids = (taskID: taskID, surfaceID: surfaceID)

        setTitle(vm, ids, "Action Required · deploy script")
        vm.reconcileAgentLifecycles()
        XCTAssertNil(lifecycle(vm, ids))
    }
}
