import XCTest
@testable import BalaganCore

final class SessionHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func binding(_ session: String, pid: Int32? = 42) -> ResumeBinding {
        ResumeBinding(id: "r", surfaceID: "s", kind: .agent, agentName: "claude", sessionID: session,
                      command: "claude --resume \(session)", pid: pid, createdAt: now, updatedAt: now)
    }

    func testANewSessionPushesTheCurrentOneToTheFrontWithoutItsPid() {
        let history = SessionHistory.archiving(current: binding("a"), newSessionID: "b", into: [], at: now)
        XCTAssertEqual(history.map(\.id), ["a"])
        XCTAssertNil(history.first?.binding.pid, "a dead session's pid may belong to another process by now")
        XCTAssertEqual(history.first?.replacedAt, now)
    }

    func testTheSameSessionReportedAgainChangesNothing() {
        // Claude reports a session twice (pre-exec, then its SessionStart hook).
        XCTAssertTrue(SessionHistory.archiving(current: binding("a"), newSessionID: "a", into: [], at: now).isEmpty)
    }

    func testASessionIsNeverListedTwiceAndTheHistoryIsCapped() {
        var history: [SessionRecord] = []
        var current = binding("s0")
        for i in 1...(SessionHistory.limit + 5) {
            history = SessionHistory.archiving(current: current, newSessionID: "s\(i)", into: history, at: now)
            current = binding("s\(i)")
        }
        XCTAssertEqual(history.count, SessionHistory.limit)
        XCTAssertEqual(history.first?.id, "s\(SessionHistory.limit + 4)")
        // Coming back to an archived session takes it out of the history.
        let back = SessionHistory.archiving(current: current, newSessionID: history[3].id, into: history, at: now)
        XCTAssertFalse(back.contains { $0.id == history[3].id })
        XCTAssertEqual(back.first?.id, current.sessionID)
    }

    func testSwitchingToAnEarlierSessionSwapsItWithTheCurrentOne() throws {
        let history = SessionHistory.archiving(current: binding("old"), newSessionID: "new", into: [], at: now)
        let switched = try XCTUnwrap(SessionHistory.switching(to: "old", current: binding("new"), history: history, at: now))
        XCTAssertEqual(switched.current.sessionID, "old")
        XCTAssertNil(switched.current.pid)
        XCTAssertEqual(switched.history.map(\.id), ["new"])
        XCTAssertNil(SessionHistory.switching(to: "missing", current: binding("new"), history: history, at: now))
    }

    func testTheTitleIsTheFirstPrompt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Add passkey login\nand keep sessions"}}"#,
            #"{"type":"user","message":{"role":"user","content":"second"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionHistory.title(transcriptAt: file.path, format: .claude), "Add passkey login")
    }
}
