import XCTest
@testable import BalaganCore

final class BalaganHomeTests: XCTestCase {
    func testDefaultsToDotBalaganInHome() {
        XCTAssertEqual(BalaganHome.root(environment: [:], homeDirectory: "/Users/a"), "/Users/a/.balagan")
    }

    func testOverrideWinsAndBlankIsIgnored() {
        XCTAssertEqual(BalaganHome.root(environment: ["BALAGAN_HOME": "/tmp/b"], homeDirectory: "/Users/a"), "/tmp/b")
        XCTAssertEqual(BalaganHome.root(environment: ["BALAGAN_HOME": "  "], homeDirectory: "/Users/a"), "/Users/a/.balagan")
    }
}
