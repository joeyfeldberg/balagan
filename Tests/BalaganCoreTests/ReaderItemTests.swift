import XCTest
@testable import BalaganCore

final class ReaderItemTests: XCTestCase {
    private func entry(_ id: String, _ kind: TranscriptEntry.Kind) -> TranscriptEntry {
        TranscriptEntry(id: id, kind: kind, text: id)
    }

    func testFoldsEachRunOfToolCallsAndThinkingIntoOneActivity() {
        let user = entry("u", .user)
        let think = entry("t", .thinking)
        let read = entry("r", .toolUse(name: "Read"))
        let answer = entry("a", .assistant)
        let edit = entry("e", .toolUse(name: "Edit"))

        let items = ReaderItem.grouping([user, think, read, answer, edit])

        XCTAssertEqual(items, [.user(user), .activity([think, read]), .prose(answer), .activity([edit])])
        XCTAssertEqual(items.map(\.id), ["user-u", "activity-t", "prose-a", "activity-e"])
        XCTAssertEqual(items.map(\.isProse), [false, false, true, false])
    }

    func testEmptyTranscriptHasNoItems() {
        XCTAssertEqual(ReaderItem.grouping([]), [])
    }
}
