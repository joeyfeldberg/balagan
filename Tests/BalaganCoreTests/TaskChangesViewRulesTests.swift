import XCTest
@testable import BalaganCore

final class TaskChangesViewRulesTests: XCTestCase {
    private func line(_ n: Int) -> DiffLine { DiffLine(kind: .added, text: "\(n)", oldNumber: nil, newNumber: n) }

    func testSummaryAgainstABase() {
        let changes = TaskChanges(baseName: "main", commitsAhead: 1, files: [
            DiffFile(path: "a", status: .modified, isUncommitted: true),
            DiffFile(path: "b", status: .added),
        ])
        XCTAssertEqual(changes.summary, "vs main · 1 commit · 2 files · 1 uncommitted")
    }

    func testSummaryOnTheBaseBranch() {
        let changes = TaskChanges(baseName: nil, commitsAhead: 0, files: [DiffFile(path: "a", status: .modified, isUncommitted: true)])
        XCTAssertEqual(changes.summary, "uncommitted only · 1 file")
    }

    func testFileToShowKeepsThePickThenPrefersReadableContent() {
        let deleted = DiffFile(path: "gone", status: .deleted)
        let binary = DiffFile(path: "img.png", status: .added, isBinary: true)
        let readable = DiffFile(path: "main.swift", status: .modified)
        let changes = TaskChanges(baseName: "main", commitsAhead: 1, files: [deleted, binary, readable])

        XCTAssertEqual(changes.fileToShow(picked: "img.png"), binary)
        XCTAssertEqual(changes.fileToShow(picked: "dropped-by-refresh"), readable)
        XCTAssertEqual(changes.fileToShow(picked: nil), readable)
        XCTAssertEqual(TaskChanges(baseName: nil, commitsAhead: 0, files: [deleted]).fileToShow(picked: nil), deleted)
        XCTAssertNil(TaskChanges(baseName: nil, commitsAhead: 0, files: []).fileToShow(picked: nil))
    }

    func testRowsFlattenHunksAndStopAtTheCap() {
        let file = DiffFile(path: "a", status: .modified, hunks: [
            DiffHunk(header: "@@ 1 @@", lines: [line(1), line(2)]),
            DiffHunk(header: "@@ 2 @@", lines: [line(3)]),
        ])

        let all = file.rows(lineCap: 10)
        XCTAssertFalse(all.truncated)
        XCTAssertEqual(all.rows, [.hunk(0, "@@ 1 @@"), .line(1, line(1)), .line(2, line(2)), .hunk(3, "@@ 2 @@"), .line(4, line(3))])

        let capped = file.rows(lineCap: 2)
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.rows.map(\.id), [0, 1, 2, 3])
    }
}
