import XCTest
@testable import BalaganCore

final class LaneReorderTests: XCTestCase {
    func testInsertionIndexCountsTheLanesLeftOfTheDragPoint() {
        let others = [100.0, 300.0, 500.0]
        XCTAssertEqual(LaneReorder.insertionIndex(dropX: 50, otherMidXs: others), 0)
        XCTAssertEqual(LaneReorder.insertionIndex(dropX: 320, otherMidXs: others), 2)
        XCTAssertEqual(LaneReorder.insertionIndex(dropX: 900, otherMidXs: others), 3)
    }

    func testMovingPlacesTheLaneAmongTheRest() {
        let lanes = ["todo", "doing", "review", "done"]
        XCTAssertEqual(LaneReorder.moving(lanes, from: 0, to: 2), ["doing", "review", "todo", "done"])
        XCTAssertEqual(LaneReorder.moving(lanes, from: 3, to: 0), ["done", "todo", "doing", "review"])
        XCTAssertEqual(LaneReorder.moving(lanes, from: 1, to: 1), lanes, "dropping where it was changes nothing")
        XCTAssertEqual(LaneReorder.moving(lanes, from: 9, to: 0), lanes)
    }
}
