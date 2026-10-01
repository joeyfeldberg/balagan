import XCTest
@testable import BalaganCore

final class TaskAgentStateTests: XCTestCase {
    // MARK: - aggregate

    func testRunningTakesPrecedenceOverEverything() {
        XCTAssertEqual(
            TaskAgentState.aggregate(lifecycles: [.needsInput, .idle, .running], hasAgentSurface: true, hibernated: false),
            .running
        )
    }

    func testNeedsInputBeatsIdleWhenNothingIsWorking() {
        XCTAssertEqual(
            TaskAgentState.aggregate(lifecycles: [.idle, .needsInput], hasAgentSurface: true, hibernated: false),
            .needsInput
        )
    }

    func testAgentSurfaceWithoutAReportedLifecycleReadsIdleNotNone() {
        XCTAssertEqual(
            TaskAgentState.aggregate(lifecycles: [nil], hasAgentSurface: true, hibernated: false),
            .idle
        )
    }

    func testNoAgentReadsNone() {
        XCTAssertEqual(
            TaskAgentState.aggregate(lifecycles: [nil, nil], hasAgentSurface: false, hibernated: false),
            TaskAgentState.none
        )
    }

    func testHibernatedIsAsleepEvenIfALifecycleLingers() {
        XCTAssertEqual(
            TaskAgentState.aggregate(lifecycles: [.running], hasAgentSurface: true, hibernated: true),
            .asleep
        )
    }

    // MARK: - parseUntil

    func testParseUntilBlankYieldsDefaultSettled() {
        XCTAssertEqual(TaskAgentState.parseUntil(nil), TaskAgentState.defaultSettled)
        XCTAssertEqual(TaskAgentState.parseUntil("   "), TaskAgentState.defaultSettled)
        XCTAssertEqual(TaskAgentState.defaultSettled, [.idle, .needsInput])
    }

    func testParseUntilSingleAndList() {
        XCTAssertEqual(TaskAgentState.parseUntil("running"), [.running])
        XCTAssertEqual(TaskAgentState.parseUntil("idle, needs-input"), [.idle, .needsInput])
    }

    func testParseUntilRejectsUnknownTokens() {
        XCTAssertNil(TaskAgentState.parseUntil("bogus"))
        XCTAssertNil(TaskAgentState.parseUntil("idle,bogus"))
    }
}
