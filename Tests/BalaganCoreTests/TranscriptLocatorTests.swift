import Foundation
import XCTest
@testable import BalaganCore

final class TranscriptLocatorTests: XCTestCase {
    private var root: URL!
    private var locator: TranscriptLocator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-locator-\(UUID().uuidString)")
        locator = TranscriptLocator(
            claudeProjectsDirectoryURL: root.appendingPathComponent("projects"),
            codexSessionsDirectoryURL: root.appendingPathComponent("sessions")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func createFile(_ relativePath: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: url)
        return url.path
    }

    /// The temp dir lives behind the /var → /private/var symlink and directory enumeration reports
    /// resolved paths, so compare both sides in symlink-resolved form.
    private func assertResolvesTo(
        _ expected: String?,
        _ actual: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func normalized(_ path: String?) -> String? {
            path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        XCTAssertEqual(normalized(actual), normalized(expected), file: file, line: line)
    }

    func testPrefersStoredPathWhenItExists() throws {
        let stored = try createFile("elsewhere/stored.jsonl")
        XCTAssertEqual(
            locator.resolve(agentName: "claude", sessionID: "sess-1", storedPath: stored),
            stored
        )
    }

    func testFallsBackToSearchWhenStoredPathIsGone() throws {
        let path = try createFile("projects/-Users-dev-repo/sess-1.jsonl")
        assertResolvesTo(
            path,
            locator.resolve(agentName: "claude", sessionID: "sess-1", storedPath: "/gone/nope.jsonl")
        )
    }

    func testFindsClaudeTranscriptAcrossProjectDirectories() throws {
        _ = try createFile("projects/-Users-dev-other/other-session.jsonl")
        let path = try createFile("projects/-Users-dev-repo-worktrees-x/sess-abc.jsonl")
        assertResolvesTo(path, locator.resolve(agentName: "claude", sessionID: "sess-abc"))
    }

    func testFindsCodexRolloutByDatedFilename() throws {
        _ = try createFile("sessions/2026/07/22/rollout-2026-07-22T09-00-00-other-id.jsonl")
        let path = try createFile("sessions/2026/07/23/rollout-2026-07-23T10-00-00-019f4c9b-c4ad.jsonl")
        assertResolvesTo(path, locator.resolve(agentName: "codex", sessionID: "019f4c9b-c4ad"))
    }

    func testCodexMatchRequiresFullSessionIDSegment() throws {
        _ = try createFile("sessions/2026/07/23/rollout-2026-07-23T10-00-00-prefix-019f4c9b.jsonl")
        XCTAssertNil(locator.resolve(agentName: "codex", sessionID: "9f4c9b"))
    }

    func testUnknownAgentSearchesBothStores() throws {
        let codexPath = try createFile("sessions/2026/07/23/rollout-2026-07-23T10-00-00-codex-sess.jsonl")
        assertResolvesTo(codexPath, locator.resolve(agentName: nil, sessionID: "codex-sess"))
        let claudePath = try createFile("projects/-Users-dev-repo/claude-sess.jsonl")
        assertResolvesTo(claudePath, locator.resolve(agentName: "unknown", sessionID: "claude-sess"))
    }

    func testMissingSessionIDAndStoredPathResolvesNil() {
        XCTAssertNil(locator.resolve(agentName: "claude", sessionID: nil))
        XCTAssertNil(locator.resolve(agentName: "claude", sessionID: "  "))
        XCTAssertNil(locator.resolve(agentName: "claude", sessionID: nil, storedPath: "/gone.jsonl"))
    }
}
