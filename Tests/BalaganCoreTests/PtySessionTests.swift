import Foundation
import XCTest
@testable import BalaganCore

final class PtySessionTests: XCTestCase {
    func testRunCapturesOutputAndExitStatus() throws {
        let result = try PtySession.run(PtyCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'hello from pty\\n'"]
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.outputString.contains("hello from pty"))
    }

    func testRunSendsInputToChildProcess() throws {
        let result = try PtySession.run(
            PtyCommand(executable: "/bin/sh", arguments: ["-c", "read line; printf \"received:$line\\n\""]),
            input: Data("typed through pty\n".utf8)
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.outputString.contains("received:typed through pty"))
    }

    func testWorkingDirectoryIsApplied() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalaganPtyTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = try PtySession.run(PtyCommand(
            executable: "/bin/pwd",
            workingDirectory: directory.path
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.outputString.contains(directory.path))
    }

    func testWindowSizeIsVisibleToChild() throws {
        let result = try PtySession.run(
            PtyCommand(executable: "/bin/stty", arguments: ["size"]),
            windowSize: PtyWindowSize(columns: 132, rows: 43)
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.outputString.contains("43 132"), result.outputString)
    }
}
