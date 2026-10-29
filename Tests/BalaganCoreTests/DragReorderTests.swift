import XCTest
@testable import BalaganCore

final class DragReorderTests: XCTestCase {
    func testInsertionIndexCountsTheLanesLeftOfTheDragPoint() {
        let others = [100.0, 300.0, 500.0]
        XCTAssertEqual(DragReorder.insertionIndex(dropAt: 50, otherMidpoints: others), 0)
        XCTAssertEqual(DragReorder.insertionIndex(dropAt: 320, otherMidpoints: others), 2)
        XCTAssertEqual(DragReorder.insertionIndex(dropAt: 900, otherMidpoints: others), 3)
    }

    func testMovingPlacesTheLaneAmongTheRest() {
        let lanes = ["todo", "doing", "review", "done"]
        XCTAssertEqual(DragReorder.moving(lanes, from: 0, to: 2), ["doing", "review", "todo", "done"])
        XCTAssertEqual(DragReorder.moving(lanes, from: 3, to: 0), ["done", "todo", "doing", "review"])
        XCTAssertEqual(DragReorder.moving(lanes, from: 1, to: 1), lanes, "dropping where it was changes nothing")
        XCTAssertEqual(DragReorder.moving(lanes, from: 9, to: 0), lanes)
    }
}
