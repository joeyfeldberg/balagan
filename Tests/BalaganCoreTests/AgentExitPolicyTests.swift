import XCTest
@testable import BalaganCore

final class AgentExitPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func outcome(
        agent: Bool = true,
        session: Bool = true,
        launchedSecondsAgo: Double? = 20,
        autoResumesSecondsAgo: [Double] = []
    ) -> AgentExitPolicy.Outcome {
        AgentExitPolicy.outcome(
            isAgentTab: agent,
            hasSession: session,
            launchedAt: launchedSecondsAgo.map { now.addingTimeInterval(-$0) },
            now: now,
            recentAutoResumes: autoResumesSecondsAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    func testAPlainShellClosesItsTab() {
        XCTAssertEqual(outcome(agent: false), .closeTab)
    }

    func testAnAgentThatQuitsRightAfterStartingIsResumed() {
        // The self-update pattern: launch, update, exit.
        XCTAssertEqual(outcome(launchedSecondsAgo: 15), .resumeAutomatically)
    }

    func testAnAgentThatQuitsLaterAsks() {
        XCTAssertEqual(outcome(launchedSecondsAgo: 30 * 60), .offerResume)
        XCTAssertEqual(outcome(launchedSecondsAgo: nil), .offerResume)
    }

    func testNoSessionOffersARestartInstead() {
        XCTAssertEqual(outcome(session: false, launchedSecondsAgo: 5), .offerRestart)
    }

    func testCrashOnStartStopsLoopingAfterTwoResumes() {
        XCTAssertEqual(outcome(autoResumesSecondsAgo: [60]), .resumeAutomatically)
        XCTAssertEqual(outcome(autoResumesSecondsAgo: [60, 30]), .offerResume)
        // Old resumes age out.
        XCTAssertEqual(outcome(autoResumesSecondsAgo: [1200.0, 1800.0]), .resumeAutomatically)
    }
}
