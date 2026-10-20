import XCTest
@testable import BalaganCore

final class LibGhosttyVersionCheckTests: XCTestCase {
    func testPinnedVersionIsAParsableRelease() {
        XCTAssertNotNil(LibGhosttyVersionCheck.majorMinor(LibGhosttyVersionCheck.pinnedVersion))
    }

    func testSameVersionIsCompatibleWithNoWarning() {
        let result = LibGhosttyVersionCheck.check(reported: "1.3.1", pinned: "1.3.1")
        XCTAssertEqual(result, .compatible(reported: "1.3.1"))
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.reported, "1.3.1")
    }

    func testPatchReleaseIsCompatible() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.0", pinned: "1.3.1"),
            .compatible(reported: "1.3.0")
        )
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.7", pinned: "1.3.1"),
            .compatible(reported: "1.3.7")
        )
    }

    func testMinorReleaseIsAMismatchThatNamesBothVersions() {
        let result = LibGhosttyVersionCheck.check(reported: "1.4.0", pinned: "1.3.1")
        XCTAssertEqual(result, .mismatch(reported: "1.4.0", pinned: "1.3.1"))
        let warning = try! XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains("1.4.0"))
        XCTAssertTrue(warning.contains("1.3.1"))
    }

    func testOlderMinorAndNewerMajorAreMismatches() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.2.3", pinned: "1.3.1"),
            .mismatch(reported: "1.2.3", pinned: "1.3.1")
        )
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "2.0.0", pinned: "1.3.1"),
            .mismatch(reported: "2.0.0", pinned: "1.3.1")
        )
    }

    func testTipBuildKeepsItsFullStringButComparesTheLeadingVersion() {
        let result = LibGhosttyVersionCheck.check(reported: "1.4.0-dev+39943e7", pinned: "1.3.1")
        XCTAssertEqual(result, .mismatch(reported: "1.4.0-dev+39943e7", pinned: "1.3.1"))
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.1-dev+abc123", pinned: "1.3.1"),
            .compatible(reported: "1.3.1-dev+abc123")
        )
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: " 1.3.1\n", pinned: "1.3.1"),
            .compatible(reported: "1.3.1")
        )
    }

    func testMissingOrUnparsableVersionIsUnknownWithAWarning() {
        for reported in [nil, "", "   ", "tip", "v", "1"] {
            let result = LibGhosttyVersionCheck.check(reported: reported, pinned: "1.3.1")
            XCTAssertEqual(result, .unknown(pinned: "1.3.1"), "reported \(reported ?? "nil")")
            XCTAssertNil(result.reported)
            XCTAssertNotNil(result.warning)
        }
    }

    func testMajorMinorParsing() {
        XCTAssertEqual(LibGhosttyVersionCheck.majorMinor("1.3.1"), .init(major: 1, minor: 3))
        XCTAssertEqual(LibGhosttyVersionCheck.majorMinor("1.4.0-dev+39943e7"), .init(major: 1, minor: 4))
        XCTAssertEqual(LibGhosttyVersionCheck.majorMinor("12.0"), .init(major: 12, minor: 0))
        XCTAssertNil(LibGhosttyVersionCheck.majorMinor("1"))
        XCTAssertNil(LibGhosttyVersionCheck.majorMinor(""))
        XCTAssertNil(LibGhosttyVersionCheck.majorMinor("tip"))
    }
}
