import XCTest
@testable import BalaganCore

final class ISO8601TimestampTests: XCTestCase {
    private let expected = Date(timeIntervalSince1970: 1_790_366_400) // 2026-09-25T20:00:00Z

    func testParsesWithoutFraction() {
        XCTAssertEqual(ISO8601Timestamp.parse("2026-09-25T20:00:00Z"), expected)
        XCTAssertEqual(ISO8601Timestamp.parse("2026-09-25T22:00:00+02:00"), expected)
    }

    func testParsesMillisecondsAsWritten() throws {
        let date = try XCTUnwrap(ISO8601Timestamp.parse("2026-09-25T20:00:00.250Z"))
        XCTAssertEqual(date.timeIntervalSince(expected), 0.25, accuracy: 0.0001)
    }

    func testCutsMicrosecondsToMilliseconds() throws {
        let date = try XCTUnwrap(ISO8601Timestamp.parse("2026-09-25T20:00:00.606556+00:00"))
        XCTAssertEqual(date.timeIntervalSince(expected), 0.606, accuracy: 0.0001)
    }

    func testPadsShortFractions() throws {
        let date = try XCTUnwrap(ISO8601Timestamp.parse("2026-09-25T20:00:00.5Z"))
        XCTAssertEqual(date.timeIntervalSince(expected), 0.5, accuracy: 0.0001)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ISO8601Timestamp.parse(""))
        XCTAssertNil(ISO8601Timestamp.parse("yesterday"))
    }
}
