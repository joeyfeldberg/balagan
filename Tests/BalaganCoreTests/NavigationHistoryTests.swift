import XCTest
@testable import BalaganCore

final class NavigationHistoryTests: XCTestCase {
    private let all: (BoardLocation) -> Bool = { _ in true }

    func testBackAndForwardRetraceVisits() {
        var history = NavigationHistory<BoardLocation>()
        history.visit(.board(projectID: nil))
        history.visit(.task("a"))
        history.visit(.task("b"))

        XCTAssertEqual(history.goBack(where: all), .task("a"))
        XCTAssertEqual(history.goBack(where: all), .board(projectID: nil))
        XCTAssertNil(history.goBack(where: all))
        XCTAssertEqual(history.current, .board(projectID: nil))

        XCTAssertEqual(history.goForward(where: all), .task("a"))
        XCTAssertEqual(history.goForward(where: all), .task("b"))
        XCTAssertNil(history.goForward(where: all))
    }

    func testVisitingSomewhereNewDropsForwardAndRepeatsAreIgnored() {
        var history = NavigationHistory<BoardLocation>()
        history.visit(.task("a"))
        history.visit(.task("b"))
        _ = history.goBack(where: all)
        history.visit(.task("a"))
        XCTAssertEqual(history.forward, [.task("b")], "revisiting where you are keeps forward")
        history.visit(.archived)
        XCTAssertTrue(history.forward.isEmpty)
        XCTAssertEqual(history.back, [.task("a")])
    }

    func testGoingBackSkipsAndForgetsPlacesThatAreGone() {
        var history = NavigationHistory<BoardLocation>()
        history.visit(.board(projectID: "p"))
        history.visit(.task("deleted"))
        history.visit(.task("c"))
        let exists: (BoardLocation) -> Bool = { $0 != .task("deleted") }

        XCTAssertTrue(history.canGoBack(where: exists))
        XCTAssertEqual(history.goBack(where: exists), .board(projectID: "p"))
        XCTAssertTrue(history.back.isEmpty)
        XCTAssertEqual(history.forward, [.task("c")])
        XCTAssertFalse(history.canGoBack(where: exists))
    }

    func testBackIsCappedAtTheLimit() {
        var history = NavigationHistory<BoardLocation>(limit: 3)
        for id in ["a", "b", "c", "d", "e"] { history.visit(.task(id)) }
        XCTAssertEqual(history.back, [.task("b"), .task("c"), .task("d")])
    }
}
