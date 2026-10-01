import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Drives the *driver* side of the title-spinner safety net: `BoardViewModel.reconcileAgentLifecycles`
/// and the per-host streak it feeds `AgentLifecycleReconciler`.
///
/// The behaviour being locked down: Claude stops its title spinner a few hundred ms *after* it opens a
/// permission dialog, while the hook sets `.needsInput` immediately. A reconcile tick landing in that
/// window used to promote the surface straight back to `.running`, and the next (spinner-absent) tick
/// then demoted it to `.idle` — a waiting agent silently reading as finished. Needs-input must therefore
/// survive one spinner tick and only flip on a second consecutive one.
final class AgentTitleStreakReconcileTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    /// The first agent-capable surface on the board (no pid recorded ⇒ the reconciler treats the process
    /// as alive, which is the live-agent case we're modelling).
    private func firstSurface(_ vm: BoardViewModel) -> (taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let task = vm.tasks.first { $0.workspace.surfaces.isEmpty == false }!
        return (task.id, task.workspace.surfaces[0].id)
    }

    private func lifecycle(_ vm: BoardViewModel, _ ids: (taskID: TaskItem.ID, surfaceID: Surface.ID)) -> AgentLifecycle? {
        vm.surfaceLifecycle[vm.hostKey(ids.taskID, ids.surfaceID)]
    }

    /// Puts a surface in the state a permission prompt produces: the spinner has been seen (so absence is
    /// trusted), it's still present right now, and a hook has just written `.needsInput`.
    private func seedWaitingAgentWithLiveSpinner(_ vm: BoardViewModel) -> (taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let ids = firstSurface(vm)
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)
        vm.setSurfaceLifecycle(.needsInput, taskID: ids.taskID, surfaceID: ids.surfaceID)
        return ids
    }

    func testNeedsInputSurvivesOneSpinnerTickAndFlipsOnTheSecond() {
        let vm = makeViewModel()
        let ids = seedWaitingAgentWithLiveSpinner(vm)

        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput, "one lagging spinner tick must not overturn the hook")

        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running, "two consecutive spinner ticks mean work really resumed")
    }

    func testSpinnerStoppingResetsTheStreakSoNeedsInputHolds() {
        let vm = makeViewModel()
        let ids = seedWaitingAgentWithLiveSpinner(vm)

        vm.reconcileAgentLifecycles()                            // streak 1 — still waiting
        // The dialog is now open and the spinner has stopped: the streak restarts, and the agent stays
        // waiting for as many ticks as the user takes to answer.
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: false)
        vm.reconcileAgentLifecycles()
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput, "spinner-absent must leave a waiting agent alone")

        // Approved: the spinner comes back and it takes two fresh ticks to read as running again.
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)
    }

    func testAHookSettingNeedsInputRestartsTheStreakMidRun() {
        let vm = makeViewModel()
        let ids = firstSurface(vm)
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)

        // A long-running turn: plenty of consecutive spinner ticks banked.
        vm.reconcileAgentLifecycles()
        vm.reconcileAgentLifecycles()
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)

        // Now the permission hook fires while the spinner is still going. The banked streak must not
        // let the very next tick undo it.
        vm.setSurfaceLifecycle(.needsInput, taskID: ids.taskID, surfaceID: ids.surfaceID)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .needsInput)
    }

    func testIdleIsPromotedOnTheFirstSpinnerTick() {
        // Recovering a *lost* running (a missed prompt-submit hook) stays as fast as it was — only the
        // needs-input promotion is deliberately slow.
        let vm = makeViewModel()
        let ids = firstSurface(vm)
        vm.setSurfaceLifecycle(.idle, taskID: ids.taskID, surfaceID: ids.surfaceID)
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)

        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)
    }

    func testSpinnerDisappearingWhileRunningFallsBackToIdle() {
        // The Esc/interrupt recovery: no hook fires, so the vanished spinner is the only evidence.
        let vm = makeViewModel()
        let ids = firstSurface(vm)
        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: true)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .running)

        vm.updateTitleWorkingSignal(taskID: ids.taskID, surfaceID: ids.surfaceID, working: false)
        vm.reconcileAgentLifecycles()
        XCTAssertEqual(lifecycle(vm, ids), .idle)
    }
}
