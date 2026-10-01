import XCTest
@testable import BalaganCore

/// Locks the per-board lanes model and its migration: a board saved before lanes existed decodes to the
/// defaults, custom lanes round-trip, and a task's status is an open string id (custom lanes hold tasks).
final class LaneTests: XCTestCase {
    private struct StatusHolder: Codable, Equatable { var status: TaskStatus }

    func testProjectDecodesDefaultsWhenLanesKeyIsAbsent() throws {
        let json = #"{"id":"p","name":"P","repoPath":"/tmp/p"}"#.data(using: .utf8)!
        let project = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(project.lanes, Lane.defaults)
    }

    func testProjectRoundTripsCustomLanes() throws {
        let lanes = Lane.defaults + [Lane(id: "review", name: "Review", colorHex: "B980FF")]
        let project = Project(id: "p", name: "P", repoPath: "/tmp/p", lanes: lanes)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.lanes, lanes)
    }

    func testEmptyLaneListFallsBackToDefaults() {
        XCTAssertEqual(Project(id: "p", name: "P", repoPath: "/tmp/p", lanes: []).lanes, Lane.defaults)
    }

    func testDefaultLaneIdsMatchTheHistoricalStatuses() {
        XCTAssertEqual(Lane.defaults.map(\.id), ["todo", "doing", "done", "parked"])
        XCTAssertEqual(TaskStatus.defaults.map(\.rawValue), ["todo", "doing", "done", "parked"])
    }

    func testTaskStatusKeepsACustomIdAndBlankFallsBackToTodo() throws {
        let custom = try JSONDecoder().decode(StatusHolder.self, from: #"{"status":"review"}"#.data(using: .utf8)!)
        XCTAssertEqual(custom.status.rawValue, "review")

        let blank = try JSONDecoder().decode(StatusHolder.self, from: #"{"status":"  "}"#.data(using: .utf8)!)
        XCTAssertEqual(blank.status, .todo)

        // The four built-ins keep their historical ids/wire form.
        for status in TaskStatus.defaults {
            let encoded = try JSONEncoder().encode(StatusHolder(status: status))
            XCTAssertEqual(try JSONDecoder().decode(StatusHolder.self, from: encoded).status, status)
        }
    }

    func testLaneSlug() {
        XCTAssertEqual(Lane.slug(for: "In Review"), "in-review")
        XCTAssertEqual(Lane.slug(for: "  Ready!!  "), "ready")
        XCTAssertEqual(Lane.slug(for: "QA / staging"), "qa-staging")
    }

    func testLaneCollapsedDefaultsToFalseWhenAbsentAndRoundTrips() throws {
        let legacy = #"{"id":"todo","name":"Todo","colorHex":"8A93A6"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Lane.self, from: legacy).collapsed, false)

        let collapsed = Lane(id: "x", name: "X", colorHex: "4C8DFF", collapsed: true)
        let decoded = try JSONDecoder().decode(Lane.self, from: JSONEncoder().encode(collapsed))
        XCTAssertTrue(decoded.collapsed)
    }
}
