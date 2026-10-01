import XCTest
@testable import BalaganCore

final class RecentTasksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testMostRecentFirstSkippingCurrentAndNeverOpened() {
        let ids = RecentTasks.ids([
            .init(id: "old", lastActiveAt: t0),
            .init(id: "never", lastActiveAt: nil),
            .init(id: "current", lastActiveAt: t0.addingTimeInterval(300)),
            .init(id: "newer", lastActiveAt: t0.addingTimeInterval(100)),
        ], excluding: "current")
        XCTAssertEqual(ids, ["newer", "old"])
    }

    func testLimit() {
        let candidates = (0..<8).map { RecentTasks.Candidate(id: "t\($0)", lastActiveAt: t0.addingTimeInterval(Double($0))) }
        XCTAssertEqual(RecentTasks.ids(candidates, excluding: nil, limit: 3), ["t7", "t6", "t5"])
    }
}
