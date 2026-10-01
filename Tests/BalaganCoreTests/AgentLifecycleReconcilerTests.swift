import XCTest
@testable import BalaganCore

final class AgentLifecycleReconcilerTests: XCTestCase {
    func testDeadProcessClearsAnyState() {
        XCTAssertNil(AgentLifecycleReconciler.reconcile(current: .running, processAlive: false))
        XCTAssertNil(AgentLifecycleReconciler.reconcile(current: .idle, processAlive: false))
        XCTAssertNil(AgentLifecycleReconciler.reconcile(current: .needsInput, processAlive: false))
        XCTAssertNil(AgentLifecycleReconciler.reconcile(current: nil, processAlive: false))
    }

    func testLiveProcessKeepsHookStateWithoutATitleSignal() {
        // With no title signal the reconciler never promotes/demotes a live agent — hooks own those.
        XCTAssertEqual(AgentLifecycleReconciler.reconcile(current: .running, processAlive: true), .running)
        XCTAssertEqual(AgentLifecycleReconciler.reconcile(current: .idle, processAlive: true), .idle)
        XCTAssertEqual(AgentLifecycleReconciler.reconcile(current: .needsInput, processAlive: true), .needsInput)
        XCTAssertNil(AgentLifecycleReconciler.reconcile(current: nil, processAlive: true))
    }

    func testTitleSpinnerRecoversALostRunning() {
        // Spinner present + feature active => running on the first observation, for a state the hooks
        // never claimed to be blocked on the user (nil / idle).
        for current in [AgentLifecycle?.none, .idle] {
            XCTAssertEqual(
                AgentLifecycleReconciler.reconcile(
                    current: current, processAlive: true, titleWorking: true, titleFeatureActive: true,
                    titleWorkingStreak: 1
                ),
                .running
            )
        }
    }

    func testNeedsInputSurvivesASingleSpinnerTick() {
        // The spinner keeps animating for a few hundred ms after the permission dialog opens, so one
        // sighting right after the hook must not overturn "waiting on the user".
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .needsInput, processAlive: true, titleWorking: true, titleFeatureActive: true,
                titleWorkingStreak: 1
            ),
            .needsInput
        )
    }

    func testNeedsInputFlipsToRunningOnTheSecondConsecutiveSpinnerTick() {
        // Two ticks (≥2s apart) of a live spinner means the turn really did resume — e.g. the user
        // approved and the PostToolUse hook was missed.
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .needsInput, processAlive: true, titleWorking: true, titleFeatureActive: true,
                titleWorkingStreak: 2
            ),
            .running
        )
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .needsInput, processAlive: true, titleWorking: true, titleFeatureActive: true,
                titleWorkingStreak: 7
            ),
            .running
        )
    }

    func testNeedsInputIsNotOverturnedWithoutStreakInformation() {
        // Default streak (0) = "no consecutive-tick evidence" => the safe answer is to leave the waiting
        // agent alone rather than promote it (and then have the next absent tick demote it to idle).
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .needsInput, processAlive: true, titleWorking: true, titleFeatureActive: true
            ),
            .needsInput
        )
    }

    func testRunningStaysRunningOnAnySpinnerTick() {
        // The streak only gates the needs-input promotion; an already-running agent is unaffected.
        for streak in [0, 1, 2] {
            XCTAssertEqual(
                AgentLifecycleReconciler.reconcile(
                    current: .running, processAlive: true, titleWorking: true, titleFeatureActive: true,
                    titleWorkingStreak: streak
                ),
                .running
            )
        }
    }

    func testNoSpinnerClearsAStuckRunning() {
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .running, processAlive: true, titleWorking: false, titleFeatureActive: true
            ),
            .idle
        )
    }

    func testNoSpinnerLeavesNeedsInputAndIdleAlone() {
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .needsInput, processAlive: true, titleWorking: false, titleFeatureActive: true
            ),
            .needsInput
        )
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .idle, processAlive: true, titleWorking: false, titleFeatureActive: true
            ),
            .idle
        )
    }

    func testTitleIgnoredUntilTheFeatureIsProvenActive() {
        // Never seen a spinner => absence is meaningless, must not demote a working agent.
        XCTAssertEqual(
            AgentLifecycleReconciler.reconcile(
                current: .running, processAlive: true, titleWorking: false, titleFeatureActive: false
            ),
            .running
        )
    }

    func testDeadProcessStillWinsOverATitleSpinner() {
        XCTAssertNil(
            AgentLifecycleReconciler.reconcile(
                current: .running, processAlive: false, titleWorking: true, titleFeatureActive: true
            )
        )
    }

    // MARK: - Codex: no hooks, so the title is the whole state machine

    private func codex(
        _ current: AgentLifecycle?,
        _ titleSignal: AgentTitleHeuristic.TitleSignal?,
        processAlive: Bool = true,
        titleFeatureActive: Bool = false
    ) -> AgentLifecycle? {
        AgentLifecycleReconciler.reconcile(
            current: current,
            processAlive: processAlive,
            agentKind: .codex,
            titleSignal: titleSignal,
            titleFeatureActive: titleFeatureActive
        )
    }

    func testCodexTitleDrivesEveryTransition() {
        // Whatever the surface currently reads as, the latest title decides.
        for current in [AgentLifecycle?.none, .idle, .running, .needsInput] {
            XCTAssertEqual(codex(current, .working), .running, "spinner ⇒ running (from \(String(describing: current)))")
            XCTAssertEqual(codex(current, .blocked), .needsInput, "Action Required ⇒ needs-input")
            XCTAssertEqual(codex(current, .idle), .idle, "a plain title ⇒ idle")
        }
    }

    func testCodexNeedsInputClearsWhenTheTitleStopsSayingActionRequired() {
        // Unlike Claude's hook-set needs-input (sticky against spinner absence), Codex's came from the
        // title, so it must leave the moment the title does — otherwise an answered prompt stays "waiting".
        XCTAssertEqual(codex(.needsInput, .idle), .idle)
        XCTAssertEqual(codex(.needsInput, .working), .running, "no two-tick streak gate for Codex")
    }

    func testCodexIgnoresTheSpinnerEverSeenLatch() {
        // `titleFeatureActive` protects a *hook-set* state from a missing spinner. Codex has no hooks,
        // and a Codex surface that has only ever shown a plain title really is idle.
        XCTAssertEqual(codex(.running, .idle, titleFeatureActive: false), .idle)
    }

    func testCodexWithoutATitleYetIsLeftAlone() {
        XCTAssertNil(codex(nil, nil))
        XCTAssertEqual(codex(.running, nil), .running)
    }

    func testCodexDeadProcessStillClears() {
        XCTAssertNil(codex(.running, .working, processAlive: false))
        XCTAssertNil(codex(.needsInput, .blocked, processAlive: false))
    }

    func testAgentKindAwareEntryPointKeepsClaudeOnTheHookDrivenPath() {
        // Claude's title never says "Action Required" — but if some tool wrote it, it must not become
        // needs-input: only the hooks may do that.
        for kind in [AgentKind?.none, .claude] {
            XCTAssertEqual(
                AgentLifecycleReconciler.reconcile(
                    current: .running, processAlive: true, agentKind: kind, titleSignal: .blocked,
                    titleFeatureActive: true
                ),
                .idle,
                "a spinner-less title only demotes running ⇒ idle on the hook-driven path"
            )
            XCTAssertEqual(
                AgentLifecycleReconciler.reconcile(
                    current: .needsInput, processAlive: true, agentKind: kind, titleSignal: .working,
                    titleFeatureActive: true, titleWorkingStreak: 1
                ),
                .needsInput,
                "the two-tick streak gate still applies"
            )
        }
    }
}
