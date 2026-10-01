import XCTest
@testable import BalaganCore

final class TerminalBackendSelectionTests: XCTestCase {
    func testUITestModeAlwaysUsesFixtureBackend() {
        let selection = TerminalBackendSelector.select(
            uiTestMode: true,
            disableRealProcesses: false,
            explicitLibGhosttyPath: "/tmp/should-not-be-needed.dylib",
            environment: [:]
        )

        XCTAssertEqual(selection.kind, .fixture)
        XCTAssertEqual(selection.reason, "real process launch disabled")
        XCTAssertFalse(selection.libGhostty.isAvailable)
    }

    func testDisableRealProcessesUsesFixtureBackend() {
        let selection = TerminalBackendSelector.select(
            uiTestMode: false,
            disableRealProcesses: true,
            environment: [:]
        )

        XCTAssertEqual(selection.kind, .fixture)
    }

    func testMissingRuntimeIsUnavailableWhenNoLinkedRuntimeExists() {
        let selection = TerminalBackendSelector.select(
            uiTestMode: false,
            disableRealProcesses: false,
            explicitLibGhosttyPath: "/tmp/balagan-missing-libghostty.dylib",
            environment: [:]
        )

        if selection.libGhostty.isAvailable {
            XCTAssertEqual(selection.kind, .libghostty)
            XCTAssertEqual(selection.reason, "libghostty runtime available")
        } else {
            XCTAssertEqual(selection.kind, .unavailable)
            XCTAssertEqual(selection.reason, "libghostty runtime unavailable")
        }
    }
}
