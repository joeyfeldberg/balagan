import XCTest
@testable import BalaganCore

final class BoardKeyboardNavigationTests: XCTestCase {
    private let columns = [["a1", "a2", "a3"], [], ["c1"], ["d1", "d2"]]

    private func next(_ from: String?, _ direction: BoardKeyboardNavigation.Direction) -> String? {
        BoardKeyboardNavigation.next(from: from, direction: direction, columns: columns)
    }

    func testAnyArrowStartsAtTheFirstCard() {
        XCTAssertEqual(next(nil, .down), "a1")
        XCTAssertEqual(next(nil, .right), "a1")
        XCTAssertEqual(next("gone", .up), "a1")
    }

    func testUpAndDownStayInTheColumnAndStopAtItsEnds() {
        XCTAssertEqual(next("a1", .down), "a2")
        XCTAssertEqual(next("a3", .down), "a3")
        XCTAssertEqual(next("a1", .up), "a1")
    }

    func testLeftAndRightSkipEmptyLanesAndKeepTheRowWhereTheyCan() {
        XCTAssertEqual(next("a3", .right), "c1", "the empty lane is skipped; c has one row")
        XCTAssertEqual(next("c1", .right), "d1")
        XCTAssertEqual(next("d2", .left), "c1")
        XCTAssertEqual(next("a2", .left), "a2", "nothing further left")
        XCTAssertEqual(BoardKeyboardNavigation.next(from: "a2", direction: .right, columns: [["a1", "a2"], ["b1", "b2", "b3"]]), "b2")
    }

    func testTheHighlightOnlySurvivesWhileTheCardIsShown() {
        XCTAssertEqual(BoardKeyboardNavigation.retained("c1", columns: columns), "c1")
        XCTAssertNil(BoardKeyboardNavigation.retained("zz", columns: columns))
    }
}
