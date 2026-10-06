import XCTest
@testable import BalaganCore

final class DiffCommentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAnchorsAddedAndContextLinesByNewNumberAndRemovedLinesByOld() {
        let added = DiffLine(kind: .added, text: "x", oldNumber: nil, newNumber: 12)
        let removed = DiffLine(kind: .removed, text: "y", oldNumber: 9, newNumber: nil)
        let context = DiffLine(kind: .context, text: "z", oldNumber: 8, newNumber: 11)
        XCTAssertEqual(DiffComment.anchor(for: added)?.side, .new)
        XCTAssertEqual(DiffComment.anchor(for: added)?.line, 12)
        XCTAssertEqual(DiffComment.anchor(for: removed)?.side, .old)
        XCTAssertEqual(DiffComment.anchor(for: removed)?.line, 9)
        XCTAssertEqual(DiffComment.anchor(for: context)?.line, 11)

        let comment = DiffComment(path: "a.swift", side: .old, line: 9, lineText: "y", body: "why?")
        XCTAssertTrue(comment.isAnchored(to: removed))
        XCTAssertFalse(comment.isAnchored(to: added))
    }

    func testComposesOneMessageGroupedByFileThenLine() {
        let comments = [
            DiffComment(path: "src/b.ts", side: .new, line: 40, lineText: "  return x", body: "Handle nil.", createdAt: t0),
            DiffComment(path: "src/a.ts", side: .new, line: 7, lineText: "import foo", body: "Unused import.", createdAt: t0),
            DiffComment(path: "src/b.ts", side: .old, line: 3, lineText: "legacy()", body: "Why was this removed?\n", createdAt: t0),
            DiffComment(path: "src/a.ts", side: .new, line: 9, lineText: "", body: "   ", createdAt: t0),
        ]
        let message = ReviewMessage.compose(comments, fileOrder: ["src/b.ts", "src/a.ts"])
        XCTAssertEqual(message, """
        I reviewed your changes and left 3 comments. Please address each one:

        src/b.ts, removed line 3
        > legacy()
        Why was this removed?

        src/b.ts:40
        > return x
        Handle nil.

        src/a.ts:7
        > import foo
        Unused import.
        """)
    }

    func testNothingToSendIsEmpty() {
        XCTAssertEqual(ReviewMessage.compose([]), "")
        XCTAssertEqual(ReviewMessage.compose([DiffComment(path: "a", side: .new, line: 1, lineText: "x", body: "  ")]), "")
    }

    func testOldBoardsWithoutCommentsStillDecode() throws {
        let task = TaskItem(id: "t", projectID: "p", title: "T", workspace: Workspace(id: "w", taskID: "t", layout: .tabs([]), selectedSurfaceID: nil, surfaces: []))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "reviewComments")
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.reviewComments)
    }
}
