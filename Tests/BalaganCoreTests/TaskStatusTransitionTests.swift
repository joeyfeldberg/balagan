import XCTest
@testable import BalaganCore

final class TaskStatusTransitionTests: XCTestCase {
    func testMoveUpdatesStatusAndTimestamp() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let movedAt = Date(timeIntervalSince1970: 1_700_000_120)
        let task = BalaganFixtures.task(status: .todo, createdAt: createdAt, updatedAt: createdAt)

        let transitioned = task.transitioned(to: .doing, at: movedAt)

        XCTAssertEqual(transitioned.status, .doing)
        XCTAssertEqual(transitioned.createdAt, createdAt)
        XCTAssertEqual(transitioned.updatedAt, movedAt)
    }

    func testMoveToAnyLaneIncludingACustomOneIsAllowed() {
        let task = BalaganFixtures.task(status: .todo)
        XCTAssertEqual(task.transitioned(to: .done, at: BalaganFixtures.laterDate).status, .done)

        let review = TaskStatus(rawValue: "review")
        XCTAssertEqual(task.transitioned(to: review, at: BalaganFixtures.laterDate).status, review)
    }

    func testSameStatusIsNoOp() {
        let task = BalaganFixtures.task(status: .parked)
        XCTAssertEqual(task.transitioned(to: .parked, at: BalaganFixtures.laterDate), task)
    }
}
