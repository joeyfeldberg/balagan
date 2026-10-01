import XCTest
@testable import BalaganApp
@testable import BalaganCore

final class BoardLanesTests: XCTestCase {
    private func makeViewModel() -> BoardViewModel {
        let seed = BoardFixtures.seed(named: "multi-project-board")
        return BoardViewModel(projects: seed.projects, tasks: seed.tasks, selectedTaskID: nil)
    }

    private func lanes(_ vm: BoardViewModel, _ projectID: Project.ID) -> [Lane] {
        vm.projects.first { $0.id == projectID }!.lanes
    }

    func testAddLaneSlugsNameUniquelyAndAssignsAColor() {
        let vm = makeViewModel()
        let p = vm.projects[0].id

        let a = vm.addLane(toProjectID: p, name: "In Review")
        XCTAssertEqual(a?.id, "in-review")
        XCTAssertEqual(a?.name, "In Review")
        XCTAssertFalse((a?.colorHex ?? "").isEmpty)

        let b = vm.addLane(toProjectID: p, name: "In Review")   // duplicate name → unique id
        XCTAssertEqual(b?.id, "in-review-2")
        XCTAssertEqual(lanes(vm, p).suffix(2).map(\.id), ["in-review", "in-review-2"])
    }

    func testRenameLane() {
        let vm = makeViewModel()
        let p = vm.projects[0].id
        vm.renameLane(projectID: p, laneID: "todo", to: "Backlog")
        XCTAssertEqual(lanes(vm, p).first { $0.id == "todo" }?.name, "Backlog")
    }

    func testMoveLaneAndClampAtEnds() {
        let vm = makeViewModel()
        let p = vm.projects[0].id
        vm.moveLane(projectID: p, laneID: "doing", by: -1)
        XCTAssertEqual(lanes(vm, p).map(\.id), ["doing", "todo", "done", "parked"])
        vm.moveLane(projectID: p, laneID: "doing", by: -1)   // already first — no-op
        XCTAssertEqual(lanes(vm, p).first?.id, "doing")
    }

    func testCannotDeleteALaneThatHasTasks() {
        let vm = makeViewModel()
        let task = vm.tasks.first!
        let p = task.projectID
        vm.move(taskID: task.id, to: .parked)

        XCTAssertFalse(vm.canDeleteLane(projectID: p, laneID: "parked"))
        XCTAssertFalse(vm.deleteLane(projectID: p, laneID: "parked"))
        XCTAssertTrue(lanes(vm, p).contains { $0.id == "parked" })
    }

    func testDeleteEmptyLanesButKeepTheLastColumn() {
        // A project with no tasks: every lane is empty and deletable, down to the last.
        let vm = BoardViewModel(
            projects: [Project(id: "p", name: "P", repoPath: "/tmp/p")],
            tasks: [],
            selectedTaskID: nil
        )
        for id in ["parked", "done", "doing"] { XCTAssertTrue(vm.deleteLane(projectID: "p", laneID: id)) }
        XCTAssertEqual(lanes(vm, "p").map(\.id), ["todo"])
        XCTAssertFalse(vm.deleteLane(projectID: "p", laneID: "todo"))
    }

    func testToggleLaneCollapsed() {
        let vm = makeViewModel()
        let p = vm.projects[0].id
        XCTAssertFalse(lanes(vm, p).first { $0.id == "doing" }!.collapsed)
        vm.toggleLaneCollapsed(projectID: p, laneID: "doing")
        XCTAssertTrue(lanes(vm, p).first { $0.id == "doing" }!.collapsed)
        vm.toggleLaneCollapsed(projectID: p, laneID: "doing")
        XCTAssertFalse(lanes(vm, p).first { $0.id == "doing" }!.collapsed)
    }
}
