import XCTest
@testable import BalaganCore

final class TmuxSessionNameTests: XCTestCase {
    func testSessionNameIsStableAndShellSafe() {
        let name = Tmux.sessionName(forTaskID: "ABC 123:feature/UI")

        XCTAssertEqual(name, "task_abc_123_feature_ui")
    }

    func testSessionCommandsUseStableSessionName() {
        XCTAssertEqual(
            Tmux.newSessionCommand(forTaskID: "task-1", cwd: "/repos/example"),
            ["tmux", "new-session", "-A", "-s", "task_task-1", "-c", "/repos/example"]
        )
        XCTAssertEqual(
            Tmux.attachCommand(forTaskID: "task-1"),
            ["tmux", "attach", "-t", "task_task-1"]
        )
    }

    func testLongSessionNamesAreBoundedAndDeterministic() {
        let taskID = String(repeating: "really-long-task-id-", count: 12)

        let first = Tmux.sessionName(forTaskID: taskID)
        let second = Tmux.sessionName(forTaskID: taskID)

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, Tmux.defaultMaxSessionNameLength)
        XCTAssertTrue(first.hasPrefix("task_"))
    }
}
