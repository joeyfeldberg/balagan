import Foundation
import SQLite3
import XCTest
@testable import BalaganCore

final class CodexSessionCaptureTests: XCTestCase {
    func testCapturesSingleNewThreadMatchingCwdAndStartTime() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("old-session", "/tmp/rollout-old.jsonl", 100, "/tmp/balagan"),
            ("new-session", "/tmp/rollout-new.jsonl", 200, "/tmp/balagan"),
            ("other-cwd-session", "/tmp/rollout-other.jsonl", 250, "/tmp/other"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )

        XCTAssertEqual(
            try capture.captureFromStateDatabase(cwd: "/tmp/balagan", startMs: 150),
            .captured("new-session")
        )
    }

    func testStateDatabaseCaptureResolvesMultipleMatchesToTheMostRecent() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("new-session-a", "/tmp/rollout-a.jsonl", 200, "/tmp/balagan"),
            ("new-session-b", "/tmp/rollout-b.jsonl", 201, "/tmp/balagan"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )

        // Two sessions for the cwd in the window → take the one created most recently, don't give up.
        XCTAssertEqual(
            try capture.captureFromStateDatabase(cwd: "/tmp/balagan", startMs: 150),
            .captured("new-session-b")
        )
    }

    func testStateDatabaseCaptureAllowsCodexCreatedAtClockSkew() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("skewed-session", "/tmp/rollout-skewed.jsonl", 140_000, "/tmp/balagan"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions")
        )

        XCTAssertEqual(
            try capture.captureFromStateDatabase(cwd: "/tmp/balagan", startMs: 200_000),
            .captured("skewed-session")
        )
    }

    func testStateDatabaseCapturePrefersExactPostLaunchMatchOverSkewWindow() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("previous-session", "/tmp/rollout-previous.jsonl", 199_000, "/tmp/balagan"),
            ("launched-session", "/tmp/rollout-launched.jsonl", 200_500, "/tmp/balagan"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions")
        )

        XCTAssertEqual(
            try capture.captureFromStateDatabase(cwd: "/tmp/balagan", startMs: 200_000),
            .captured("launched-session")
        )
    }

    func testStateDatabaseCaptureNormalizesCwdBeforeMatching() throws {
        let directory = temporaryDirectory()
        let repoURL = directory.appendingPathComponent("repo")
        let nestedURL = repoURL.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("normalized-session", "/tmp/rollout-normalized.jsonl", 200, nestedURL.standardizedFileURL.path),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )

        let nonStandardCwd = repoURL
            .appendingPathComponent(".")
            .appendingPathComponent("nested")
            .path
        XCTAssertEqual(
            try capture.captureFromStateDatabase(cwd: nonStandardCwd, startMs: 150),
            .captured("normalized-session")
        )
    }

    func testRolloutFileFallbackParsesSessionMeta() throws {
        let directory = temporaryDirectory()
        let sessionsDirectory = directory.appendingPathComponent("sessions/2026/06/08")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-test.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"rollout-session-1"}}
        {"type":"turn_context","payload":{"cwd":"/tmp/balagan"}}

        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: rolloutURL.path)
        let capture = CodexSessionCapture(
            stateDatabaseURL: directory.appendingPathComponent("missing.sqlite"),
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )

        XCTAssertEqual(
            try capture.capture(cwd: "/tmp/balagan", startMs: Int64(now.addingTimeInterval(-1).timeIntervalSince1970 * 1000)),
            .captured("rollout-session-1")
        )
    }

    func testReopenRecoveryCreatesTrustedCodexResumeBindingFromPersistedLaunchMetadata() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("unrelated-old-session", "/tmp/rollout-old.jsonl", 100, "/tmp/balagan"),
            ("recovered-session", "/tmp/rollout-recovered.jsonl", 220, "/tmp/balagan"),
            ("other-cwd-session", "/tmp/rollout-other.jsonl", 230, "/tmp/other"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = pendingCodexSurface(captureStartedAtMs: 200)

        let result = try capture.recoverCodexResumeBinding(
            surface: surface,
            taskID: "task-1",
            workspaceID: "workspace-1",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        guard case .recovered(let recoveredSurface) = result else {
            return XCTFail("Expected recovered surface, got \(result).")
        }
        let binding = try XCTUnwrap(recoveredSurface.resumeBinding)
        XCTAssertEqual(binding.source, .agentHook)
        XCTAssertEqual(binding.trust, .trusted)
        XCTAssertEqual(binding.agentName, "codex")
        XCTAssertEqual(binding.sessionID, "recovered-session")
        XCTAssertEqual(binding.command, "codex resume recovered-session")
        XCTAssertTrue(binding.autoResume)

        let launchRequest = TerminalLaunchPlanner.launchRequest(for: recoveredSurface, taskID: "task-1")
        XCTAssertEqual(launchRequest?.source, .trustedResume)
        XCTAssertEqual(launchRequest?.displayCommand, "codex resume recovered-session")
    }

    func testReopenRecoveryCanUseRolloutWhenItMatchesCwdAndLaunchWindow() throws {
        let directory = temporaryDirectory()
        let sessionsDirectory = directory.appendingPathComponent("sessions/2026/06/08")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-test.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"rollout-recovered-session"}}
        {"type":"turn_context","payload":{"cwd":"/tmp/balagan"}}

        """.write(to: rolloutURL, atomically: true, encoding: .utf8)
        let modifiedAt = Date(timeIntervalSince1970: 2)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: rolloutURL.path)
        let capture = CodexSessionCapture(
            stateDatabaseURL: directory.appendingPathComponent("missing.sqlite"),
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = pendingCodexSurface(captureStartedAtMs: 1_500)

        let result = try capture.recoverCodexResumeBinding(surface: surface, taskID: "task-1")

        guard case .recovered(let recoveredSurface) = result else {
            return XCTFail("Expected rollout recovery, got \(result).")
        }
        XCTAssertEqual(recoveredSurface.resumeBinding?.sessionID, "rollout-recovered-session")
    }

    func testLegacyPendingCodexSurfaceWithoutLaunchMetadataRecoversSingleMatchingLocalStateSession() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("legacy-recovered-session", "/tmp/rollout-legacy.jsonl", 220, "/tmp/balagan"),
            ("other-cwd-session", "/tmp/rollout-other.jsonl", 230, "/tmp/other"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = legacyPendingCodexSurface()

        let result = try capture.recoverCodexResumeBinding(
            surface: surface,
            taskID: "task-1",
            workspaceID: "workspace-1",
            environment: ["PATH": "/usr/bin:/bin"],
            recoveredAt: Date(timeIntervalSince1970: 1)
        )

        guard case .recovered(let recoveredSurface) = result else {
            return XCTFail("Expected legacy recovery, got \(result).")
        }
        let binding = try XCTUnwrap(recoveredSurface.resumeBinding)
        XCTAssertEqual(binding.source, .agentHook)
        XCTAssertEqual(binding.trust, .trusted)
        XCTAssertEqual(binding.sessionID, "legacy-recovered-session")
        XCTAssertEqual(binding.command, "codex resume legacy-recovered-session")

        let launchRequest = TerminalLaunchPlanner.launchRequest(for: recoveredSurface, taskID: "task-1")
        XCTAssertEqual(launchRequest?.source, .trustedResume)
        XCTAssertEqual(launchRequest?.displayCommand, "codex resume legacy-recovered-session")
    }

    func testLegacyPendingCodexSurfaceRecoversTheMostRecentMatchingLocalStateSession() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("legacy-session-a", "/tmp/rollout-a.jsonl", 220, "/tmp/balagan"),
            ("legacy-session-b", "/tmp/rollout-b.jsonl", 221, "/tmp/balagan"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = legacyPendingCodexSurface()

        let result = try capture.recoverCodexResumeBinding(
            surface: surface,
            taskID: "task-1",
            recoveredAt: Date(timeIntervalSince1970: 1)
        )
        guard case .recovered(let recoveredSurface) = result else {
            return XCTFail("Expected recovery of the most recent session, got \(result).")
        }
        XCTAssertEqual(recoveredSurface.resumeBinding?.sessionID, "legacy-session-b")
        XCTAssertEqual(
            TerminalLaunchPlanner.launchRequest(for: recoveredSurface, taskID: "task-1")?.displayCommand,
            "codex resume legacy-session-b"
        )
    }

    func testLegacyPendingCodexSurfaceWithoutLaunchMetadataDoesNotLaunchFreshWhenStateIsMissing() throws {
        let directory = temporaryDirectory()
        let capture = CodexSessionCapture(
            stateDatabaseURL: directory.appendingPathComponent("missing.sqlite"),
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = legacyPendingCodexSurface()

        XCTAssertEqual(
            try capture.recoverCodexResumeBinding(
                surface: surface,
                taskID: "task-1",
                recoveredAt: Date(timeIntervalSince1970: 1)
            ),
            .missing
        )
        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "task-1"))
    }

    func testReopenRecoveryDoesNotStartFreshCodexWhenStateIsMissing() throws {
        let directory = temporaryDirectory()
        let capture = CodexSessionCapture(
            stateDatabaseURL: directory.appendingPathComponent("missing.sqlite"),
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = pendingCodexSurface(captureStartedAtMs: 200)

        XCTAssertEqual(
            try capture.recoverCodexResumeBinding(surface: surface, taskID: "task-1"),
            .missing
        )
        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "task-1"))
    }

    func testReopenRecoveryResolvesMultipleMatchesToTheMostRecent() throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        try createCodexStateDatabase(at: dbURL, rows: [
            ("session-a", "/tmp/rollout-a.jsonl", 220, "/tmp/balagan"),
            ("session-b", "/tmp/rollout-b.jsonl", 221, "/tmp/balagan"),
        ])
        let capture = CodexSessionCapture(
            stateDatabaseURL: dbURL,
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let surface = pendingCodexSurface(captureStartedAtMs: 200)

        let result = try capture.recoverCodexResumeBinding(surface: surface, taskID: "task-1")
        guard case .recovered(let recoveredSurface) = result else {
            return XCTFail("Expected recovery of the most recent session, got \(result).")
        }
        XCTAssertEqual(recoveredSurface.resumeBinding?.sessionID, "session-b")
        XCTAssertEqual(
            TerminalLaunchPlanner.launchRequest(for: recoveredSurface, taskID: "task-1")?.source,
            .trustedResume
        )
    }

    func testReopenRecoveryLeavesCapturedBindingUntouched() throws {
        let directory = temporaryDirectory()
        let capture = CodexSessionCapture(
            stateDatabaseURL: directory.appendingPathComponent("missing.sqlite"),
            sessionsDirectoryURL: directory.appendingPathComponent("sessions"),
            startSkewAllowanceMs: 0
        )
        let existingBinding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "codex",
            sessionID: "already-captured",
            command: "codex resume already-captured",
            trust: .trusted,
            source: .agentHook,
            autoResume: true
        )
        let surface = pendingCodexSurface(captureStartedAtMs: 200, resumeBinding: existingBinding)

        XCTAssertEqual(
            try capture.recoverCodexResumeBinding(surface: surface, taskID: "task-1"),
            .notNeeded
        )
        XCTAssertEqual(
            TerminalLaunchPlanner.launchRequest(for: surface, taskID: "task-1")?.displayCommand,
            "codex resume already-captured"
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("balagan-codex-capture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createCodexStateDatabase(
        at url: URL,
        rows: [(id: String, rolloutPath: String, createdAtMs: Int64, cwd: String)]
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "CodexSessionCaptureTests", code: 1)
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE threads (id TEXT, rollout_path TEXT, created_at_ms INTEGER, cwd TEXT)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO threads VALUES (?, ?, ?, ?)", -1, &statement, nil),
            SQLITE_OK
        )
        guard let statement else {
            throw NSError(domain: "CodexSessionCaptureTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            bindText(row.id, to: statement, at: 1)
            bindText(row.rolloutPath, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, row.createdAtMs)
            bindText(row.cwd, to: statement, at: 4)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func pendingCodexSurface(
        captureStartedAtMs: Int64,
        resumeBinding: ResumeBinding? = nil
    ) -> Surface {
        BalaganFixtures.surface(
            id: "surface-agent",
            workspaceID: "workspace-1",
            cwd: "/tmp/balagan",
            startupCommand: "'/tmp/balagan build/balagan-agent' codex --model gpt-5",
            resumeBinding: resumeBinding,
            scrollbackSnapshot: "$ balagan-agent codex\nCodex session starting",
            agentLaunchMetadata: AgentLaunchMetadata(
                agentName: "codex",
                startupCommand: "'/tmp/balagan build/balagan-agent' codex --model gpt-5",
                cwd: "/tmp/balagan",
                launchedAtMs: captureStartedAtMs,
                captureStartedAtMs: captureStartedAtMs,
                wrapperPath: "/tmp/balagan build/balagan-agent"
            )
        )
    }

    private func legacyPendingCodexSurface() -> Surface {
        BalaganFixtures.surface(
            id: "surface-agent",
            workspaceID: "workspace-1",
            cwd: "/tmp/balagan",
            startupCommand: "balagan-agent codex",
            resumeBinding: nil,
            scrollbackSnapshot: "$ balagan-agent codex\nCodex session starting",
            agentLaunchMetadata: nil
        )
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
