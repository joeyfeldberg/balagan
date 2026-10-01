import Foundation
import BalaganCore
import XCTest
@testable import BalaganApp

/// The agent-hook → app wire, over a real AF_UNIX socket and with no app launched: the wrapper's
/// sender (`SessionReportEventSocketSender`) writing to the app's listener (`SessionReportServer`).
/// The end-to-end version of this — hooks moving a task's state as `balagan state` reports it —
/// is `scripts/hook-lifecycle-smoke.sh`.
final class SessionReportServerSocketTests: XCTestCase {
    /// Sockets live in a short `/tmp` directory on purpose: `sun_path` caps the path at ~104 bytes and
    /// the per-user temp dir (`/var/folders/<…>/T/`) plus a file name gets close to it.
    private func makeSocketPath() throws -> String {
        let directory = "/tmp/tb-srtest-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory + "/sr.sock"
    }

    private func lifecycleEvent(_ lifecycle: AgentLifecycle, toolName: String? = nil) -> SessionReportEvent {
        SessionReportEvent(
            event: .lifecycle,
            taskID: "task-1",
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            agentName: "claude",
            lifecycle: lifecycle.rawValue,
            toolName: toolName
        )
    }

    func testNeedsInputRunningIdleRoundTripOverARealSocket() throws {
        let socketPath = try makeSocketPath()
        var received: [SessionReportEvent] = []
        let delivered = expectation(description: "three lifecycle reports delivered")
        delivered.expectedFulfillmentCount = 3

        // The server dispatches onto the main queue; `wait(for:)` spins the main run loop, so the
        // read source fires without launching the app.
        let server = try SessionReportServer(socketPath: socketPath) { event in
            received.append(event)
            delivered.fulfill()
        }
        server.start()
        defer { server.stop() }

        try SessionReportEventSocketSender.send(
            event: lifecycleEvent(.needsInput, toolName: "Bash"),
            socketPath: socketPath
        )
        try SessionReportEventSocketSender.send(event: lifecycleEvent(.running), socketPath: socketPath)
        try SessionReportEventSocketSender.send(event: lifecycleEvent(.idle), socketPath: socketPath)

        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(received.map(\.lifecycle), ["needs-input", "running", "idle"])
        XCTAssertEqual(received.map(\.event), [.lifecycle, .lifecycle, .lifecycle])
        XCTAssertEqual(received.first?.toolName, "Bash")
        XCTAssertEqual(Set(received.map(\.surfaceID)), ["surface-1"])
    }

    /// A leftover socket file from a previous run (the app is killed, not shut down) must not stop the
    /// next launch binding — the server unlinks before it binds.
    func testServerBindsOverAStaleSocketFile() throws {
        let socketPath = try makeSocketPath()
        try Data("stale".utf8).write(to: URL(fileURLWithPath: socketPath))

        let delivered = expectation(description: "report delivered after rebinding")
        let server = try SessionReportServer(socketPath: socketPath) { _ in delivered.fulfill() }
        server.start()
        defer { server.stop() }

        try SessionReportEventSocketSender.send(event: lifecycleEvent(.running), socketPath: socketPath)

        wait(for: [delivered], timeout: 5)
    }

    func testSendingToAnAbsentSocketReportsConnectFailure() throws {
        let socketPath = try makeSocketPath()

        XCTAssertThrowsError(
            try SessionReportEventSocketSender.send(event: lifecycleEvent(.running), socketPath: socketPath)
        ) { error in
            guard case .connectFailed = error as? SessionReportEventSocketError else {
                return XCTFail("expected connectFailed, got \(error)")
            }
            // This is the failure the wrapper's hook log has to name (`send-failed: connect: …`).
            XCTAssertTrue(AgentHookLogOutcome.sendFailure(error).text.hasPrefix("send-failed: connect:"))
        }
    }
}
