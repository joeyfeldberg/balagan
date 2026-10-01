import Darwin
import XCTest
@testable import BalaganApp

/// `LaunchOptions.parse` decomposition: argument parsing, the boolean/flag switch, and the
/// `sun_path`-length clamp on the session-report socket path.
final class LaunchOptionsParseTests: XCTestCase {
    func testParseArgumentsPopulatesPathsAndFlags() {
        let options = LaunchOptions.parse([
            "BalaganApp",
            "--fixture", "resumable-task",
            "--state-path", "/tmp/state.json",
            "--database", "/tmp/board.sqlite",
            "--artifact-dir", "/tmp/art",
            "--ui-test-mode",
            "--control-socket", "/tmp/control.sock",
        ])

        XCTAssertEqual(options.fixtureName, "resumable-task")
        XCTAssertTrue(options.fixtureNameWasExplicit)
        XCTAssertEqual(options.statePath?.path, "/tmp/state.json")
        XCTAssertEqual(options.databasePath?.path, "/tmp/board.sqlite")
        XCTAssertEqual(options.artifactDirectory?.path, "/tmp/art")
        XCTAssertTrue(options.uiTestMode)
        XCTAssertEqual(options.controlSocketPath, "/tmp/control.sock")
    }

    func testDefaultsWhenNoArgumentsGiven() {
        let options = LaunchOptions.parse(["BalaganApp", "--ui-test-mode"])

        // The default fixture is used and not marked explicit.
        XCTAssertEqual(options.fixtureName, "multi-project-running")
        XCTAssertFalse(options.fixtureNameWasExplicit)
        // In UI-test mode the default database path is not synthesized.
        XCTAssertNil(options.databasePath)
        XCTAssertFalse(options.usesDefaultDatabase)
        XCTAssertFalse(options.runUIFlowSmoke)
        XCTAssertFalse(options.captureTerminalState)
    }

    func testExplicitSessionReportSocketIsPreservedWhenItFits() {
        let options = LaunchOptions.parse([
            "BalaganApp",
            "--ui-test-mode",
            "--session-report-socket", "/tmp/short-sr.sock",
        ])

        XCTAssertEqual(options.sessionReportSocketPath, "/tmp/short-sr.sock")
    }

    func testResolveSessionReportSocketPathClampsLongArtifactPath() {
        // A deeply nested artifact directory pushes the derived socket path past the sun_path cap;
        // the resolver must fall back to a short /tmp path instead of overflowing.
        let longDirectory = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 200))
        let resolved = LaunchOptions.resolveSessionReportSocketPath(
            explicit: nil,
            artifactDirectory: longDirectory
        )

        let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertLessThan(resolved.utf8.count, maxSocketPathLength)
        XCTAssertTrue(resolved.hasPrefix("/tmp/tb-"))
        XCTAssertTrue(resolved.hasSuffix("-sr.sock"))
    }

    func testResolveSessionReportSocketPathDerivesFromArtifactDirectoryWhenItFits() {
        let resolved = LaunchOptions.resolveSessionReportSocketPath(
            explicit: nil,
            artifactDirectory: URL(fileURLWithPath: "/tmp/art"),
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(resolved, "/tmp/art/balagan-session-report.sock")
    }

    /// With neither flag, the socket is the stable `~/.balagan/session-report.sock` (beside
    /// `control.sock`) rather than a per-launch random `/tmp` path.
    func testResolveSessionReportSocketPathDefaultsToTheStableHomePath() {
        let resolved = LaunchOptions.resolveSessionReportSocketPath(
            explicit: nil,
            artifactDirectory: nil,
            homeDirectory: "/Users/tester"
        )

        XCTAssertEqual(resolved, "/Users/tester/.balagan/session-report.sock")
    }

    func testExplicitAndArtifactSocketsWinOverTheStableDefault() {
        XCTAssertEqual(
            LaunchOptions.resolveSessionReportSocketPath(
                explicit: "/tmp/tb-hs-1-sr.sock",
                artifactDirectory: URL(fileURLWithPath: "/tmp/art"),
                homeDirectory: "/Users/tester"
            ),
            "/tmp/tb-hs-1-sr.sock"
        )
        XCTAssertEqual(
            LaunchOptions.resolveSessionReportSocketPath(
                explicit: nil,
                artifactDirectory: URL(fileURLWithPath: "/tmp/art"),
                homeDirectory: "/Users/tester"
            ),
            "/tmp/art/balagan-session-report.sock"
        )
    }

    /// An unreasonably long home directory still has to yield a bindable path.
    func testResolveSessionReportSocketPathClampsLongHomeDirectory() {
        let resolved = LaunchOptions.resolveSessionReportSocketPath(
            explicit: nil,
            artifactDirectory: nil,
            homeDirectory: "/Users/" + String(repeating: "a", count: 200)
        )

        let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertLessThan(resolved.utf8.count, maxSocketPathLength)
        XCTAssertTrue(resolved.hasPrefix("/tmp/tb-"))
    }
}
