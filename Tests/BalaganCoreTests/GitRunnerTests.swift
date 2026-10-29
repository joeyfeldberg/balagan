import XCTest
@testable import BalaganCore

final class GitRunnerTests: XCTestCase {
    private func makeRepo() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-runner-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertNotNil(GitRunner.run(["init", "-q"], in: directory))
        return directory
    }

    /// More output than a pipe buffer holds: a runner that waits before reading would hang here.
    func testLargeOutputDoesNotDeadlock() throws {
        let repo = try makeRepo()
        let name = String(repeating: "untracked-file-with-a-long-name-", count: 2)
        for index in 0..<2_000 {
            FileManager.default.createFile(atPath: "\(repo)/\(name)\(index).txt", contents: Data())
        }

        let output = try XCTUnwrap(GitRunner.run(["status", "--porcelain"], in: repo))
        XCTAssertGreaterThan(output.text.utf8.count, 64 * 1024)
        XCTAssertFalse(output.truncated)
        XCTAssertFalse(GitWorktreeManager.isWorktreeClean(at: repo))
    }

    func testLimitTruncates() throws {
        let repo = try makeRepo()
        for index in 0..<50 {
            FileManager.default.createFile(atPath: "\(repo)/file-\(index).txt", contents: Data())
        }
        let output = try XCTUnwrap(GitRunner.run(["status", "--porcelain"], in: repo, limit: 100))
        XCTAssertEqual(output.text.utf8.count, 100)
        XCTAssertTrue(output.truncated)
    }

    func testFailureIsNil() throws {
        let notARepo = FileManager.default.temporaryDirectory.path
        XCTAssertNil(GitRunner.run(["rev-parse", "--verify", "no-such-ref-\(UUID().uuidString)"], in: notARepo))
    }
}
