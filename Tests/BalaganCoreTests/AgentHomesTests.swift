import XCTest
@testable import BalaganCore

final class AgentHomesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/a")

    func testCodex() {
        XCTAssertEqual(AgentHomes.codex(environment: [:], homeDirectory: home).path, "/Users/a/.codex")
        XCTAssertEqual(AgentHomes.codex(environment: ["CODEX_HOME": "/data/codex"], homeDirectory: home).path, "/data/codex")
        XCTAssertEqual(AgentHomes.codex(environment: ["CODEX_HOME": " "], homeDirectory: home).path, "/Users/a/.codex")
        XCTAssertEqual(
            AgentHomes.codex(environment: ["CODEX_HOME": "/data/codex", "BALAGAN_CODEX_CAPTURE_HOME": "/tmp/h"], homeDirectory: home).path,
            "/tmp/h/.codex"
        )
    }

    func testClaude() {
        XCTAssertEqual(AgentHomes.claude(environment: [:], homeDirectory: home).path, "/Users/a/.claude")
        XCTAssertEqual(AgentHomes.claude(environment: ["CLAUDE_CONFIG_DIR": "/data/claude"], homeDirectory: home).path, "/data/claude")
    }

    func testTranscriptLocatorFollowsTheAgentHomes() {
        let locator = TranscriptLocator.fromEnvironment(["CODEX_HOME": "/data/codex", "CLAUDE_CONFIG_DIR": "/data/claude"])
        XCTAssertEqual(locator.codexSessionsDirectoryURL.path, "/data/codex/sessions")
        XCTAssertEqual(locator.claudeProjectsDirectoryURL.path, "/data/claude/projects")
    }
}
