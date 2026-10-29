import XCTest
@testable import BalaganCore

final class ContractStringsTests: XCTestCase {
    func testAccessibilitySlug() {
        XCTAssertEqual("  Build kanban shell ".accessibilitySlug, "build-kanban-shell")
        XCTAssertEqual("Fix: login/logout!!".accessibilitySlug, "fix-login-logout")
        XCTAssertEqual("???".accessibilitySlug, "item")
    }

    func testSafeArtifactComponent() {
        XCTAssertEqual("task-1/surface a.txt".safeArtifactComponent, "task-1-surface-a.txt")
        XCTAssertEqual("ok_name-1.2".safeArtifactComponent, "ok_name-1.2")
    }
}
