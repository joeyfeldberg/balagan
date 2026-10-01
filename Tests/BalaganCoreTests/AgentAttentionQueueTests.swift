import XCTest
@testable import BalaganCore

final class AgentAttentionQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ task: String, _ reason: AgentAttentionQueue.Reason, _ offset: TimeInterval?) -> AgentAttentionQueue.Entry {
        .init(taskID: task, surfaceID: "s", reason: reason, since: offset.map { t0.addingTimeInterval($0) })
    }

    func testWaitingComeFirstOldestFirstThenFinished() {
        let ordered = AgentAttentionQueue.ordered([
            entry("finished-old", .finished, 0),
            entry("waiting-new", .waiting, 60),
            entry("waiting-old", .waiting, 10),
            entry("waiting-untimed", .waiting, nil),
        ])
        XCTAssertEqual(ordered.map(\.taskID), ["waiting-old", "waiting-new", "waiting-untimed", "finished-old"])
    }

    func testNextFromOffQueueGoesToTheHead() {
        let entries = [entry("a", .waiting, 10), entry("b", .waiting, 0)]
        XCTAssertEqual(AgentAttentionQueue.next(after: nil, surfaceID: nil, in: entries)?.taskID, "b")
        XCTAssertEqual(AgentAttentionQueue.next(after: "elsewhere", surfaceID: "s", in: entries)?.taskID, "b")
    }

    func testNextWalksAndWraps() {
        let entries = [entry("a", .waiting, 0), entry("b", .waiting, 10), entry("c", .finished, 0)]
        XCTAssertEqual(AgentAttentionQueue.next(after: "a", surfaceID: "s", in: entries)?.taskID, "b")
        XCTAssertEqual(AgentAttentionQueue.next(after: "b", surfaceID: "s", in: entries)?.taskID, "c")
        XCTAssertEqual(AgentAttentionQueue.next(after: "c", surfaceID: "s", in: entries)?.taskID, "a")
    }

    func testNextIsNilWhenNothingElseNeedsYou() {
        XCTAssertNil(AgentAttentionQueue.next(after: nil, surfaceID: nil, in: []))
        XCTAssertNil(AgentAttentionQueue.next(after: "a", surfaceID: "s", in: [entry("a", .waiting, 0)]))
    }

    func testSameTaskDifferentSurfaceIsADifferentStop() {
        let entries = [
            AgentAttentionQueue.Entry(taskID: "a", surfaceID: "one", reason: .waiting, since: t0),
            AgentAttentionQueue.Entry(taskID: "a", surfaceID: "two", reason: .waiting, since: t0.addingTimeInterval(1)),
        ]
        XCTAssertEqual(AgentAttentionQueue.next(after: "a", surfaceID: "one", in: entries)?.surfaceID, "two")
    }
}

final class SidebarTaskListTests: XCTestCase {
    private func task(_ id: String, project: String = "p", status: TaskStatus, archived: Bool = false) -> TaskItem {
        TaskItem(
            id: id,
            projectID: project,
            title: id,
            status: status,
            workspace: Workspace(id: "w-\(id)", taskID: id),
            archivedAt: archived ? Date() : nil
        )
    }

    func testOrdersByLaneThenBoardOrder() {
        let project = Project(id: "p", name: "P", repoPath: "/r")
        let tasks = [
            task("parked", status: .parked),
            task("doing-1", status: .doing),
            task("todo", status: .todo),
            task("doing-2", status: .doing),
        ]
        XCTAssertEqual(SidebarTaskList.tasks(for: project, in: tasks).map(\.id), ["todo", "doing-1", "doing-2", "parked"])
    }

    func testFollowsTheProjectsCustomLaneOrder() {
        var project = Project(id: "p", name: "P", repoPath: "/r")
        project.lanes = [Lane.defaults[1], Lane.defaults[0]]   // Doing before Todo
        let tasks = [task("todo", status: .todo), task("doing", status: .doing), task("orphan", status: TaskStatus(rawValue: "gone"))]
        XCTAssertEqual(SidebarTaskList.tasks(for: project, in: tasks).map(\.id), ["doing", "todo", "orphan"])
    }

    func testLeavesOutDoneArchivedOtherProjectsAndTerminals() {
        let project = Project(id: "p", name: "P", repoPath: "/r")
        var terminals = task("terminals", status: .todo)
        terminals.projectTerminals = true
        let tasks = [
            task("done", status: .done),
            task("archived", status: .todo, archived: true),
            task("other", project: "q", status: .todo),
            terminals,
            task("kept", status: .todo),
        ]
        XCTAssertEqual(SidebarTaskList.tasks(for: project, in: tasks).map(\.id), ["kept"])
    }

    func testKeepsADoneTaskThatStillNeedsYou() {
        let project = Project(id: "p", name: "P", repoPath: "/r")
        let tasks = [task("done", status: .done)]
        XCTAssertEqual(SidebarTaskList.tasks(for: project, in: tasks, keep: { $0.id == "done" }).map(\.id), ["done"])
    }
}
