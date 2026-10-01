import XCTest
@testable import BalaganCore

final class ProjectFilteringTests: XCTestCase {
    func testFilteringByProjectPreservesTaskOrder() {
        let board = BalaganFixtures.boardState()

        let tasks = board.tasks(forProjectID: "balagan")

        XCTAssertEqual(tasks.map(\.id), ["build-board", "resume-codex"])
    }

    func testNilProjectFilterReturnsAllTasks() {
        let board = BalaganFixtures.boardState()

        let tasks = board.tasks(forProjectID: nil)

        XCTAssertEqual(tasks.map(\.id), ["build-board", "resume-codex", "write-docs"])
    }

    func testUnknownProjectFilterReturnsEmptyList() {
        let board = BalaganFixtures.boardState()

        XCTAssertTrue(board.tasks(forProjectID: "missing-project").isEmpty)
    }
}
