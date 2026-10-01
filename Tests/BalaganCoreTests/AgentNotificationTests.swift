import XCTest
@testable import BalaganCore

final class AgentNotificationTests: XCTestCase {
    func testGenuineBlocksAreNeedsInput() {
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "permission_prompt"), .needsInput)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "worker_permission_prompt"), .needsInput)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "elicitation_dialog"), .needsInput)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "elicitation_url_dialog"), .needsInput)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "agent_needs_input"), .needsInput)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_stale"), .needsInput)
    }

    /// The regression: the ~60s idle reminder must NOT read as blocked (this was the false "waiting" dot
    /// on a finished, idle agent).
    func testIdlePromptIsIdleNotNeedsInput() {
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "idle_prompt"), .idle)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "agent_completed"), .idle)
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_disabled"), .idle)
    }

    func testAutoResumeFiredIsRunning() {
        XCTAssertEqual(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_fired"), .running)
    }

    /// Quota auto-resume bookkeeping says nothing about whether the agent is working or blocked.
    func testQuotaAutoResumeBookkeepingLeavesStateUnchanged() {
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_armed"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_cancelled"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "quota_auto_resume_offer"))
    }

    /// Transient / ambiguous / unrecognized / absent types leave the working state untouched, rather
    /// than risk a spurious "waiting" — the other hooks (PermissionRequest/PreToolUse/PostToolUse/Stop)
    /// drive those transitions.
    func testAmbiguousAndUnknownTypesReportNothing() {
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "auth_success"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "elicitation_complete"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "elicitation_response"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: "a_future_type_we_dont_know"))
        XCTAssertNil(AgentNotification.lifecycle(forNotificationType: nil))
    }
}
