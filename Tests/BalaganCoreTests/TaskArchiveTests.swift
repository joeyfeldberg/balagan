import XCTest
@testable import BalaganCore

final class TaskArchiveTests: XCTestCase {
    private func task(id: String = "t", archivedAt: Date?) -> TaskItem {
        TaskItem(
            id: id,
            projectID: "p",
            title: "T",
            workspace: Workspace(id: "w", taskID: id),
            archivedAt: archivedAt
        )
    }

    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testActiveTaskHasNoArchiveState() {
        let active = task(archivedAt: nil)
        XCTAssertFalse(active.isArchived)
        XCTAssertNil(active.daysUntilAutoDelete(now: now, retentionDays: 30))
        XCTAssertFalse(active.isArchivedAndExpired(now: now, retentionDays: 30))
    }

    func testArchivedFlag() {
        XCTAssertTrue(task(archivedAt: now).isArchived)
    }

    func testDaysUntilAutoDeleteCountsDown() {
        // Archived just now → ~30 days left.
        XCTAssertEqual(task(archivedAt: now).daysUntilAutoDelete(now: now, retentionDays: 30), 30)
        // Archived 28 days ago → 2 days left.
        XCTAssertEqual(task(archivedAt: daysAgo(28)).daysUntilAutoDelete(now: now, retentionDays: 30), 2)
        // Archived 29.5 days ago → rounds up to 1 ("tomorrow").
        XCTAssertEqual(task(archivedAt: daysAgo(29.5)).daysUntilAutoDelete(now: now, retentionDays: 30), 1)
    }

    func testExpiryBoundary() {
        // Exactly at the window: 30 days ago is the cutoff; strictly older expires.
        XCTAssertFalse(task(archivedAt: daysAgo(29.9)).isArchivedAndExpired(now: now, retentionDays: 30))
        XCTAssertFalse(task(archivedAt: daysAgo(30)).isArchivedAndExpired(now: now, retentionDays: 30))
        XCTAssertTrue(task(archivedAt: daysAgo(30.1)).isArchivedAndExpired(now: now, retentionDays: 30))
        XCTAssertTrue(task(archivedAt: daysAgo(45)).isArchivedAndExpired(now: now, retentionDays: 30))
    }

    func testOverdueDaysAreNonPositive() {
        XCTAssertLessThanOrEqual(task(archivedAt: daysAgo(31)).daysUntilAutoDelete(now: now, retentionDays: 30)!, 0)
    }
}
