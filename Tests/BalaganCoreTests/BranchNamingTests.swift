import XCTest
@testable import BalaganCore

final class BranchNamingTests: XCTestCase {
    func testSlugLowercasesAndHyphenates() {
        XCTAssertEqual(BranchNaming.slug(from: "Fix login redirect"), "fix-login-redirect")
        XCTAssertEqual(BranchNaming.slug(from: "Add cool README with screenshots"),
                       "add-cool-readme-with-screenshots")
    }

    func testCollapsesRunsAndTrimsEdges() {
        XCTAssertEqual(BranchNaming.slug(from: "  Fix: the!!! bug  "), "fix-the-bug")
        XCTAssertEqual(BranchNaming.slug(from: "feature/login — v2"), "feature-login-v2")
        XCTAssertEqual(BranchNaming.slug(from: "---weird---"), "weird")
    }

    func testEmptyForNoUsableCharacters() {
        XCTAssertEqual(BranchNaming.slug(from: ""), "")
        XCTAssertEqual(BranchNaming.slug(from: "   "), "")
        XCTAssertEqual(BranchNaming.slug(from: "!!!"), "")
    }

    func testLengthCapAndNoTrailingHyphen() {
        let slug = BranchNaming.slug(from: String(repeating: "a", count: 80), maxLength: 10)
        XCTAssertEqual(slug, String(repeating: "a", count: 10))

        // A cap landing mid-gap must not leave a trailing hyphen.
        let capped = BranchNaming.slug(from: "abcde fghij klmno", maxLength: 6)
        XCTAssertFalse(capped.hasSuffix("-"))
        XCTAssertEqual(capped, "abcde")
    }
}
