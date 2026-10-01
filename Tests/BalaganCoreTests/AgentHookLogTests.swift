import XCTest
@testable import BalaganCore

/// The wrapper's hook log: line format, path resolution, and the size cap / rotation.
final class AgentHookLogTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_756_000_000)

    private func makeTemporaryDirectory() throws -> String {
        // Kept in /tmp with a short name: the log lives next to AF_UNIX sockets in real use, and the
        // per-user temp dir is long enough to make those paths overflow sun_path.
        let path = "/tmp/tb-hooklog-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - Line format

    func testSentLineCarriesEveryRoutingFieldAndNoPayload() {
        let entry = AgentHookLogEntry(
            timestamp: timestamp,
            event: "permission-request",
            lifecycle: "needs-input",
            taskID: "task-1",
            surfaceID: "surface-1",
            toolName: "Bash",
            outcome: .sent
        )

        XCTAssertEqual(
            entry.line,
            "2025-08-24T01:46:40.000Z event=permission-request lifecycle=needs-input "
                + "task=task-1 surface=surface-1 tool=Bash outcome=sent"
        )
    }

    func testAbsentFieldsRenderAsDashes() {
        let entry = AgentHookLogEntry(timestamp: timestamp, event: "stop", outcome: .droppedMissingEnv)

        XCTAssertEqual(
            entry.line,
            "2025-08-24T01:46:40.000Z event=stop lifecycle=- task=- surface=- tool=- outcome=dropped: missing-env"
        )
    }

    func testOutcomeTexts() {
        XCTAssertEqual(AgentHookLogOutcome.sent.text, "sent")
        XCTAssertEqual(AgentHookLogOutcome.droppedSubagent.text, "dropped: subagent")
        XCTAssertEqual(AgentHookLogOutcome.droppedNoMapping.text, "dropped: no-mapping")
        XCTAssertEqual(AgentHookLogOutcome.droppedMissingEnv.text, "dropped: missing-env")
        XCTAssertEqual(AgentHookLogOutcome.droppedNoSessionID.text, "dropped: no-session-id")
    }

    func testSendFailureDescribesErrnoAndNotTheSocketPath() {
        let outcome = AgentHookLogOutcome.sendFailure(
            SessionReportEventSocketError.connectFailed(socketPath: "/tmp/whatever.sock", errno: ECONNREFUSED)
        )

        XCTAssertEqual(outcome.text, "send-failed: connect: Connection refused (errno 61)")
        XCTAssertFalse(outcome.text.contains("/tmp/whatever.sock"))
    }

    func testSendFailureCoversTheOtherSocketErrors() {
        XCTAssertEqual(
            AgentHookLogOutcome.sendFailure(SessionReportEventSocketError.pathTooLong("/x")).text,
            "send-failed: socket path too long"
        )
        XCTAssertEqual(
            AgentHookLogOutcome.sendFailure(
                SessionReportEventSocketError.writeFailed(socketPath: "/x", errno: EPIPE)
            ).text,
            "send-failed: write: Broken pipe (errno 32)"
        )
    }

    func testMultilineValuesNeverBreakTheOneLinePerHookContract() {
        let entry = AgentHookLogEntry(
            timestamp: timestamp,
            event: "pre-tool",
            taskID: "task\nwith newline",
            toolName: "  ",
            outcome: .sent
        )

        XCTAssertFalse(entry.line.contains("\n"))
        XCTAssertTrue(entry.line.contains("task=task_with_newline"))
        XCTAssertTrue(entry.line.contains("tool=-"))
    }

    // MARK: - Path resolution

    func testDefaultPathSitsBesideTheControlSocket() {
        XCTAssertEqual(
            AgentHookLog.resolvePath(environment: [:], homeDirectory: "/Users/tester"),
            "/Users/tester/.balagan/agent-hooks.log"
        )
    }

    func testEnvironmentOverridesPath() {
        XCTAssertEqual(
            AgentHookLog.resolvePath(
                environment: ["BALAGAN_HOOK_LOG": "/tmp/hooks.log"],
                homeDirectory: "/Users/tester"
            ),
            "/tmp/hooks.log"
        )
    }

    func testOffDisablesLogging() {
        XCTAssertNil(
            AgentHookLog.resolvePath(environment: ["BALAGAN_HOOK_LOG": "off"], homeDirectory: "/Users/tester")
        )
        XCTAssertNil(
            AgentHookLog.resolvePath(environment: ["BALAGAN_HOOK_LOG": " OFF "], homeDirectory: "/Users/tester")
        )
    }

    func testBlankOverrideFallsBackToTheDefault() {
        XCTAssertEqual(
            AgentHookLog.resolvePath(environment: ["BALAGAN_HOOK_LOG": "  "], homeDirectory: "/Users/tester"),
            "/Users/tester/.balagan/agent-hooks.log"
        )
    }

    // MARK: - Rotation

    func testShouldRotateOnlyWhenTheAppendWouldCrossTheCap() {
        XCTAssertFalse(AgentHookLog.shouldRotate(currentByteCount: 0, appendingByteCount: 120))
        XCTAssertFalse(
            AgentHookLog.shouldRotate(currentByteCount: AgentHookLog.maximumBytes - 10, appendingByteCount: 10)
        )
        XCTAssertTrue(
            AgentHookLog.shouldRotate(currentByteCount: AgentHookLog.maximumBytes - 10, appendingByteCount: 11)
        )
    }

    func testAppendCreatesTheDirectoryAndAppendsOneLinePerEntry() throws {
        let path = try makeTemporaryDirectory() + "/nested/agent-hooks.log"

        AgentHookLog.append(AgentHookLogEntry(timestamp: timestamp, event: "stop", outcome: .sent), toPath: path)
        AgentHookLog.append(
            AgentHookLogEntry(timestamp: timestamp, event: "pre-tool", outcome: .droppedSubagent),
            toPath: path
        )

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("outcome=sent"))
        XCTAssertTrue(lines[1].hasSuffix("outcome=dropped: subagent"))
    }

    func testAppendRotatesOnceTheFileExceedsTheCap() throws {
        let path = try makeTemporaryDirectory() + "/agent-hooks.log"
        try String(repeating: "x", count: AgentHookLog.maximumBytes).write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )

        AgentHookLog.append(AgentHookLogEntry(timestamp: timestamp, event: "stop", outcome: .sent), toPath: path)

        let rotated = AgentHookLog.rotatedPath(for: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.hasSuffix("outcome=sent\n"))
        XCTAssertLessThan(contents.utf8.count, AgentHookLog.maximumBytes)
        // Only one generation is kept: a second rotation replaces the previous `.1`.
        try String(repeating: "y", count: AgentHookLog.maximumBytes).write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
        AgentHookLog.append(AgentHookLogEntry(timestamp: timestamp, event: "stop", outcome: .sent), toPath: path)
        XCTAssertTrue(try String(contentsOfFile: rotated, encoding: .utf8).hasPrefix("y"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated + ".1"))
    }

    func testAppendWithLoggingDisabledWritesNothing() throws {
        let directory = try makeTemporaryDirectory()

        AgentHookLog.append(
            AgentHookLogEntry(timestamp: timestamp, event: "stop", outcome: .sent),
            environment: ["BALAGAN_HOOK_LOG": "off"],
            homeDirectory: directory
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), [])
    }
}
