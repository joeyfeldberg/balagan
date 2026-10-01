import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Regression suite for the agent-status consolidation.
///
/// Root cause being locked down: a `Surface.ID` is only unique *within a workspace* (extra tabs get an
/// id slugged from their title, de-duped against that one workspace), but the runtime status maps
/// (`surfaceLifecycle`, `surfacesNeedingAttention`, `titleWorkingSignals`) and the session-menu item
/// ids are keyed by `Surface.ID` globally. So two different tasks that each have a tab slugging to the
/// same id (e.g. "command-palette-agent-menu" in the reported screenshot) share one status slot —
/// producing duplicate "Running agents" rows against a badge of 1, and spinners/attention that bleed
/// across unrelated tasks.
///
/// Each test asserts a behavioural invariant through the public view-model surface, so it survives the
/// internal re-key. They reproduce the bug (red) before the fix and must stay green after.
final class AgentStatusConsolidationTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    private func task(_ vm: BoardViewModel, _ id: TaskItem.ID) -> TaskItem {
        vm.tasks.first { $0.id == id }!
    }

    /// Give two distinct tasks an agent tab whose title slugs to the same `Surface.ID` — exactly the
    /// screenshot scenario. Returns the two task ids and the colliding surface id.
    @discardableResult
    private func seedCollidingAgentTabs(_ vm: BoardViewModel) -> (a: TaskItem.ID, b: TaskItem.ID, surfaceID: Surface.ID) {
        let ids = vm.tasks.map(\.id)
        let a = ids[0], b = ids[1]
        vm.createSurface(taskID: a, title: "command palette agent menu", cwd: "/tmp/a", startupCommand: nil)
        vm.createSurface(taskID: b, title: "command palette agent menu", cwd: "/tmp/b", startupCommand: nil)
        let sidA = task(vm, a).workspace.surfaces.last!.id
        let sidB = task(vm, b).workspace.surfaces.last!.id
        XCTAssertEqual(sidA, sidB, "precondition: extra-tab ids collide across workspaces")
        return (a, b, sidA)
    }

    /// Report an agent working-state through the real hook path (`applyReportedSessionCapture`).
    private func reportLifecycle(_ vm: BoardViewModel, taskID: TaskItem.ID, surfaceID: Surface.ID, _ lifecycle: String) {
        let workspaceID = task(vm, taskID).workspace.id
        _ = vm.applyReportedSessionCapture(SessionReportEvent(
            event: .lifecycle,
            taskID: taskID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            lifecycle: lifecycle
        ))
    }

    // MARK: - The invariants

    func testBadgeAndMenuCountAgree() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "running")

        // One agent is running; the badge and the menu must say the same thing.
        let sessions = vm.activeAgentSessions()
        XCTAssertEqual(vm.runningAgentCount, sessions.filter { $0.lifecycle == .running }.count,
                       "titlebar badge and Running-agents rows must count identically")
        XCTAssertEqual(vm.runningAgentCount, 1)
        XCTAssertEqual(vm.waitingAgentCount, 0)
    }

    /// The waiting badge is bound to the same list the "Waiting for you" rows come from, exactly like
    /// the running badge — one menu, two badges, one source of truth.
    func testWaitingBadgeAndMenuCountAgree() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "needs-input")
        reportLifecycle(vm, taskID: c.b, surfaceID: c.surfaceID, "running")

        let sessions = vm.activeAgentSessions()
        XCTAssertEqual(vm.waitingAgentCount, sessions.filter { $0.lifecycle == .needsInput }.count)
        XCTAssertEqual(vm.runningAgentCount, sessions.filter { $0.lifecycle == .running }.count)
        XCTAssertEqual(vm.waitingAgentCount, 1)
        XCTAssertEqual(vm.runningAgentCount, 1)
        XCTAssertEqual(sessions.count, 2, "the menu lists both working and waiting agents")
    }

    func testActiveAgentsMenuHasNoDuplicateIdentifiers() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "running")
        reportLifecycle(vm, taskID: c.b, surfaceID: c.surfaceID, "needs-input")

        let ids = vm.activeAgentSessions().map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "the menu must not contain duplicate Identifiable ids")
    }

    func testRunningStateDoesNotBleedAcrossTasks() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "running")

        XCTAssertTrue(vm.taskIsRunning(task(vm, c.a)))
        XCTAssertFalse(vm.taskIsRunning(task(vm, c.b)),
                       "task B must not read as running just because it shares a surface slug with A")
    }

    func testAgentStateDoesNotBleedAcrossTasks() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "needs-input")

        XCTAssertEqual(vm.taskAgentState(task(vm, c.a)), .needsInput)
        XCTAssertNotEqual(vm.taskAgentState(task(vm, c.b)), .needsInput,
                          "task B must not read as waiting because of A's colliding surface")
    }

    func testAttentionDoesNotBleedAcrossTasks() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        // Make the surfaces agents so the flag is agent-gated the same way the live path is.
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "idle")
        reportLifecycle(vm, taskID: c.b, surfaceID: c.surfaceID, "idle")

        vm.flagSurfaceNeedsAttention(taskID: c.a, surfaceID: c.surfaceID)

        XCTAssertTrue(vm.taskNeedsAttention(task(vm, c.a)))
        XCTAssertFalse(vm.taskNeedsAttention(task(vm, c.b)),
                       "flagging A must not light up B's card via the shared surface key")
    }

    func testSleptTaskNeverCountsAsRunningEvenOnALateEvent() {
        let vm = makeViewModel()
        let c = seedCollidingAgentTabs(vm)
        // Simulate the task being asleep, then a late lifecycle report arriving for it.
        vm.hibernatedTaskIDs.insert(c.a)
        reportLifecycle(vm, taskID: c.a, surfaceID: c.surfaceID, "running")

        XCTAssertFalse(vm.taskIsRunning(task(vm, c.a)))
        XCTAssertEqual(vm.runningAgentCount, 0, "a slept task must not contribute to the running count")
        XCTAssertEqual(vm.activeAgentSessions().count, 0, "nor to the menu behind the badge")
    }
}
