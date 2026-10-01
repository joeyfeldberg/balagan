import Foundation
import XCTest
@testable import BalaganCore

final class SessionReportEventTests: XCTestCase {
    func testParsesSessionStartReportEvent() throws {
        let payload = """
        {
          "event": "session-start",
          "taskID": "task-1",
          "workspaceID": "workspace-1",
          "surfaceID": "surface-1",
          "agentName": "codex",
          "sessionID": "session-123",
          "pid": 4242,
          "executablePath": "/opt/homebrew/bin/codex",
          "argv": ["codex", "resume"],
          "cwd": "/tmp/balagan",
          "transcriptPath": "/tmp/sessions/rollout-session-123.jsonl",
          "status": "running",
          "command": "codex",
          "environment": {
            "PATH": "/usr/bin:/bin",
            "API_TOKEN": "secret"
          },
          "reportedAt": "2026-06-07T12:00:00Z"
        }
        """

        let event = try SessionReportEventParser.parseLine(payload)

        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.taskID, "task-1")
        XCTAssertEqual(event.workspaceID, "workspace-1")
        XCTAssertEqual(event.surfaceID, "surface-1")
        XCTAssertEqual(event.agentName, "codex")
        XCTAssertEqual(event.sessionID, "session-123")
        XCTAssertEqual(event.pid, 4242)
        XCTAssertEqual(event.executablePath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(event.argv, ["codex", "resume"])
        XCTAssertEqual(event.cwd, "/tmp/balagan")
        XCTAssertEqual(event.transcriptPath, "/tmp/sessions/rollout-session-123.jsonl")
        XCTAssertEqual(event.status, "running")
        XCTAssertEqual(event.command, "codex")
        XCTAssertEqual(event.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(event.environment["API_TOKEN"], "secret")
        XCTAssertEqual(event.reportedAt, ISO8601DateFormatter().date(from: "2026-06-07T12:00:00Z"))
    }

    func testEncodesLineDelimitedEvent() throws {
        let event = SessionReportEvent(
            event: .cwd,
            taskID: "task-1",
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            cwd: "/tmp/balagan"
        )

        let line = try SessionReportEventParser.encodeLine(event)
        XCTAssertEqual(line.last, 0x0a)
        XCTAssertEqual(try SessionReportEventParser.parse(line.dropLast()), event)
    }
}
