import XCTest
@testable import BalaganApp
@testable import BalaganCore

/// Covers how a waiting/finished agent reaches the user: the in-app attention highlight and the
/// app-posted desktop banners that replace Claude's own (now disabled) idle/permission nudges.
///
/// The decision lives in `AgentAttentionPolicy` (pure, Core); these drive it through the real
/// view-model funnel (`setSurfaceLifecycle`) with the banner poster swapped for a capture.
final class AgentWaitingAttentionTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        let vm = BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
        // Headless: never touch the real notification centre, and pin "is Balagan frontmost".
        // Banners are off by default under XCTest; these tests capture them, so opt back in.
        vm.agentNotificationsEnabled = true
        vm.appIsFrontmost = { true }
        vm.waitingBannerDelay = 0
        return vm
    }

    private func task(_ vm: BoardViewModel, _ id: TaskItem.ID) -> TaskItem {
        vm.tasks.first { $0.id == id }!
    }

    /// Swaps in a capturing banner poster and returns the box it fills.
    private func captureBanners(_ vm: BoardViewModel) -> BannerBox {
        let box = BannerBox()
        vm.postAgentBanner = { box.posted.append($0) }
        return box
    }

    private final class BannerBox {
        var posted: [AgentBanner] = []
    }

    /// First task's only surface — the unit every one of these tests drives.
    private func firstSurface(_ vm: BoardViewModel) -> (taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let task = vm.tasks[0]
        return (task.id, task.workspace.surfaces[0].id)
    }

    private func view(_ vm: BoardViewModel, _ target: (taskID: TaskItem.ID, surfaceID: Surface.ID)) {
        vm.selectedTaskID = target.taskID
        vm.selectedSurfaceID = target.surfaceID
    }

    // MARK: - Attention highlight

    func testWaitingFlagsAttentionWhenNotViewed() {
        let vm = makeViewModel()
        _ = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(vm.surfaceNeedsAttention(taskID: target.taskID, surfaceID: target.surfaceID),
                      "an agent blocked on a surface you aren't looking at must badge it")
        XCTAssertTrue(vm.taskIsWaiting(task(vm, target.taskID)))
        XCTAssertTrue(vm.surfaceIsWaiting(taskID: target.taskID, surfaceID: target.surfaceID))
    }

    func testWaitingDoesNotFlagAttentionOnTheViewedSurface() {
        let vm = makeViewModel()
        _ = captureBanners(vm)
        let target = firstSurface(vm)
        view(vm, target)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertFalse(vm.surfaceNeedsAttention(taskID: target.taskID, surfaceID: target.surfaceID),
                       "you're already looking at it — no unread badge")
        XCTAssertTrue(vm.taskIsWaiting(task(vm, target.taskID)),
                      "but the live waiting state still renders (the card/tab glyph)")
    }

    func testProjectRowAggregatesWaitingAndRunning() {
        let vm = makeViewModel()
        _ = captureBanners(vm)
        let first = firstSurface(vm)
        let firstProject = task(vm, first.taskID).projectID

        vm.setSurfaceLifecycle(.needsInput, taskID: first.taskID, surfaceID: first.surfaceID)
        XCTAssertEqual(vm.projectAgentState(firstProject), .needsInput)

        // Running outranks waiting for the same project.
        let second = vm.tasks.first { $0.projectID == firstProject && $0.id != first.taskID }
        if let second, let surfaceID = second.workspace.surfaces.first?.id {
            vm.setSurfaceLifecycle(.running, taskID: second.id, surfaceID: surfaceID)
            XCTAssertEqual(vm.projectAgentState(firstProject), .running)
        }
    }

    // MARK: - Waiting banner (delayed + re-validated)

    func testWaitingBannerFiresWhenStillWaiting() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertEqual(box.posted.count, 1)
        XCTAssertEqual(box.posted.first?.title, task(vm, target.taskID).title)
        XCTAssertEqual(box.posted.first?.body, "The agent is waiting for your input")
        XCTAssertEqual(box.posted.first?.surfaceID, target.surfaceID)
    }

    func testWaitingBannerIsDroppedIfTheAgentUnblocksFirst() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        // The user approved the prompt within the delay: PreToolUse re-asserts running.
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(box.posted.isEmpty, "a prompt answered inside the delay must never buzz")
        XCTAssertTrue(vm.pendingWaitingBanners.isEmpty, "and the pending banner is retired")
    }

    func testWaitingBannerIsDroppedWhenTheUserWalksOverToIt() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        view(vm, target)   // still needsInput, but now focused
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(box.posted.isEmpty)
    }

    func testWaitingBannerStillFiresWhenViewedButBalaganIsInTheBackground() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)
        view(vm, target)
        vm.appIsFrontmost = { false }

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertEqual(box.posted.count, 1, "you can't see a tab in an app you're not in")
    }

    func testOnlyOneWaitingBannerIsPendingPerSurface() {
        let vm = makeViewModel()
        _ = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertEqual(vm.pendingWaitingBanners.count, 1)
    }

    func testNoBannerWhenNotificationsAreDisabled() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        vm.agentNotificationsEnabled = false   // --ui-test-mode
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(box.posted.isEmpty)
        XCTAssertTrue(vm.pendingWaitingBanners.isEmpty, "nothing was ever scheduled")
    }

    func testWaitingBannerIsArmedEvenWhenTheUserIsLookingAtIt() {
        // The common case: the prompt appears in the tab you're working in. The banner must still be
        // armed — whether it fires is decided at the end of the delay, not at the transition.
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)
        view(vm, target)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertEqual(vm.pendingWaitingBanners.count, 1, "armed despite being focused")
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)
        XCTAssertTrue(box.posted.isEmpty, "still looking at it when the delay ran out: dropped")
    }

    func testWaitingBannerRearmsWhenTheUserWalksAwayLater() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)
        view(vm, target)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)   // dropped: focused
        XCTAssertTrue(box.posted.isEmpty)

        // ...then the user switches to another task (the selection sink calls this).
        vm.selectedTaskID = nil
        vm.selectedSurfaceID = nil
        vm.rearmWaitingBannersAfterFocusChange()
        XCTAssertEqual(vm.pendingWaitingBanners.count, 1, "re-armed on losing focus")
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)
        XCTAssertEqual(box.posted.count, 1)
        XCTAssertEqual(box.posted.first?.body, "The agent is waiting for your input")
    }

    func testWaitingBannerRearmsAtMostOncePerEpisode() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)   // posted (unviewed)
        XCTAssertEqual(box.posted.count, 1)

        // Walk over and back again: no second nag for the same question.
        view(vm, target)
        vm.rearmWaitingBannersAfterFocusChange()
        vm.selectedTaskID = nil
        vm.rearmWaitingBannersAfterFocusChange()
        XCTAssertTrue(vm.pendingWaitingBanners.isEmpty, "already posted for this episode")

        // The agent unblocks and blocks again: that's a new episode and may buzz again.
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)
        XCTAssertEqual(box.posted.count, 2)
    }

    func testRearmSkipsFocusedAndNonWaitingSurfaces() {
        let vm = makeViewModel()
        _ = captureBanners(vm)
        let target = firstSurface(vm)
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.rearmWaitingBannersAfterFocusChange()
        XCTAssertTrue(vm.pendingWaitingBanners.isEmpty, "running surfaces never arm a waiting banner")

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)
        view(vm, target)
        vm.rearmWaitingBannersAfterFocusChange()
        XCTAssertTrue(vm.pendingWaitingBanners.isEmpty, "the surface you're looking at never re-arms")
    }

    // MARK: - Finished banner

    func testFinishedBannerPostsImmediatelyOnRunningToIdleOffScreen() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)

        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        XCTAssertTrue(box.posted.isEmpty, "starting work is not news")

        vm.setSurfaceLifecycle(.idle, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertEqual(box.posted.count, 1)
        XCTAssertEqual(box.posted.first?.body, "The agent finished")
        XCTAssertEqual(box.posted.first?.taskID, target.taskID)
        XCTAssertTrue(vm.surfaceNeedsAttention(taskID: target.taskID, surfaceID: target.surfaceID),
                      "the existing finished-off-screen highlight is unchanged")
    }

    func testFinishedBannerIsSuppressedOnTheFocusedSurface() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)
        view(vm, target)

        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.idle, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(box.posted.isEmpty)
        XCTAssertFalse(vm.surfaceNeedsAttention(taskID: target.taskID, surfaceID: target.surfaceID))
    }

    // MARK: - Hibernation

    func testHibernatedTaskNeverFlagsOrPosts() {
        let vm = makeViewModel()
        let box = captureBanners(vm)
        let target = firstSurface(vm)
        vm.hibernatedTaskIDs.insert(target.taskID)

        vm.setSurfaceLifecycle(.needsInput, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.deliverWaitingBanner(taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.running, taskID: target.taskID, surfaceID: target.surfaceID)
        vm.setSurfaceLifecycle(.idle, taskID: target.taskID, surfaceID: target.surfaceID)

        XCTAssertTrue(box.posted.isEmpty, "a slept task's agents are dead — a late edge must not buzz")
        XCTAssertFalse(vm.surfaceNeedsAttention(taskID: target.taskID, surfaceID: target.surfaceID))
        XCTAssertFalse(vm.surfaceIsWaiting(taskID: target.taskID, surfaceID: target.surfaceID))
        XCTAssertEqual(vm.taskAgentState(task(vm, target.taskID)), .asleep)
    }

    // MARK: - The pure policy

    func testPolicyBannerCopyUsesTheAgentName() {
        XCTAssertEqual(AgentAttentionPolicy.waitingBody(agentName: "claude"), "Claude is waiting for your input")
        XCTAssertEqual(AgentAttentionPolicy.finishedBody(agentName: "codex"), "Codex finished")
        XCTAssertEqual(AgentAttentionPolicy.finishedBody(agentName: nil), "The agent finished")
        XCTAssertEqual(AgentAttentionPolicy.agentDisplayName("  "), "The agent")
    }

    func testPolicyIgnoresUninterestingTransitions() {
        let context = AgentAttentionPolicy.Context(
            isViewedSurface: false,
            appIsFrontmost: false,
            isHibernated: false,
            notificationsEnabled: true
        )
        // Re-asserted needs-input (PreToolUse churn) must not re-badge or re-buzz.
        XCTAssertEqual(
            AgentAttentionPolicy.evaluate(previous: .needsInput, next: .needsInput, context: context),
            .none
        )
        // idle → running, and a cleared state, are silent.
        XCTAssertEqual(
            AgentAttentionPolicy.evaluate(previous: .idle, next: .running, context: context),
            .none
        )
        XCTAssertEqual(
            AgentAttentionPolicy.evaluate(previous: .running, next: nil, context: context),
            .none
        )
    }
}
