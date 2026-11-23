import CGhosttyShim
import XCTest
@testable import BalaganCore

final class LibGhosttyVersionCheckTests: XCTestCase {
    func testVerifiedVersionsAreParsableReleases() {
        XCTAssertFalse(LibGhosttyVersionCheck.verifiedVersions.isEmpty)
        for version in LibGhosttyVersionCheck.verifiedVersions {
            XCTAssertNotNil(LibGhosttyVersionCheck.majorMinor(version), version)
        }
    }

    func testAReleaseMatchingAnyVerifiedOneIsCompatible() {
        let verified = ["1.3.1", "1.4.0"]
        for reported in ["1.3.1", "1.3.4", "1.4.0", "1.4.2"] {
            XCTAssertEqual(
                LibGhosttyVersionCheck.check(reported: reported, verified: verified),
                .compatible(reported: reported)
            )
        }
        let newer = LibGhosttyVersionCheck.check(reported: "1.5.0", verified: verified)
        XCTAssertEqual(newer, .mismatch(reported: "1.5.0", verified: verified))
        let warning = try! XCTUnwrap(newer.warning)
        XCTAssertTrue(warning.contains("1.5.0"))
        XCTAssertTrue(warning.contains("1.3.1, 1.4.0"))
    }

    /// The shim picks its action numbers with its own lookup when the library opens, and the app
    /// words its warning from `check`. A version one accepts and the other doesn't would either warn
    /// about events that work or stay quiet about events that are off.
    func testTheShimsLookupAgreesWithTheCheck() {
        let known = LibGhosttyVersionCheck.verifiedVersions
        let samples = known + [
            "1.3.0", "1.3.9", "1.4.7-dev+39943e7", " 1.4.0\n", "1.2.9", "1.99.0", "2.0.0", "0.9.0",
            "tip", "v", "1", "", "   ",
        ]
        for reported in samples {
            let compatible: Bool
            if case .compatible = LibGhosttyVersionCheck.check(reported: reported) {
                compatible = true
            } else {
                compatible = false
            }
            XCTAssertEqual(balagan_ghostty_version_is_verified(reported), compatible, "reported \"\(reported)\"")
        }
        XCTAssertFalse(balagan_ghostty_version_is_verified(nil))
        XCTAssertNil(balagan_ghostty_verified_version(known.count))
    }

    func testSameVersionIsCompatibleWithNoWarning() {
        let result = LibGhosttyVersionCheck.check(reported: "1.3.1", verified: ["1.3.1"])
        XCTAssertEqual(result, .compatible(reported: "1.3.1"))
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.reported, "1.3.1")
    }

    func testPatchReleaseIsCompatible() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.0", verified: ["1.3.1"]),
            .compatible(reported: "1.3.0")
        )
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.7", verified: ["1.3.1"]),
            .compatible(reported: "1.3.7")
        )
    }

    func testMinorReleaseIsAMismatchThatNamesBothVersions() {
        let result = LibGhosttyVersionCheck.check(reported: "1.4.0", verified: ["1.3.1"])
        XCTAssertEqual(result, .mismatch(reported: "1.4.0", verified: ["1.3.1"]))
        let warning = try! XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains("1.4.0"))
        XCTAssertTrue(warning.contains("1.3.1"))
    }

    func testOlderMinorAndNewerMajorAreMismatches() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.2.3", verified: ["1.3.1"]),
            .mismatch(reported: "1.2.3", verified: ["1.3.1"])
        )
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "2.0.0", verified: ["1.3.1"]),
            .mismatch(reported: "2.0.0", verified: ["1.3.1"])
        )
    }

    func testTipBuildKeepsItsFullStringButComparesTheLeadingVersion() {
        let result = LibGhosttyVersionCheck.check(reported: "1.4.0-dev+39943e7", verified: ["1.3.1"])
        XCTAssertEqual(result, .mismatch(reported: "1.4.0-dev+39943e7", verified: ["1.3.1"]))
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: "1.3.1-dev+abc123", verified: ["1.3.1"]),
            .compatible(reported: "1.3.1-dev+abc123")
        )
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(
            LibGhosttyVersionCheck.check(reported: " 1.3.1\n", verified: ["1.3.1"]),
            .compatible(reported: "1.3.1")
        )
    }

    func testMissingOrUnparsableVersionIsUnknownWithAWarning() {
        for reported in [nil, "", "   ", "tip", "v", "1"] {
            let result = LibGhosttyVersionCheck.check(reported: reported, verified: ["1.3.1"])
            XCTAssertEqual(result, .unknown(verified: ["1.3.1"]), "reported \(reported ?? "nil")")
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
