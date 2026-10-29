import XCTest
@testable import BalaganCore

final class CountedTests: XCTestCase {
    func testSingularOnlyForOne() {
        XCTAssertEqual(0.counted("task"), "0 tasks")
        XCTAssertEqual(1.counted("task"), "1 task")
        XCTAssertEqual(2.counted("tool call"), "2 tool calls")
    }
}
