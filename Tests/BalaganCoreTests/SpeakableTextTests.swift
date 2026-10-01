import XCTest
@testable import BalaganCore

final class SpeakableTextTests: XCTestCase {
    func testStripsEmphasisHeadingsAndBullets() {
        let markdown = """
        ## What changed

        The **login** flow now uses *token* checks.

        - added a `guard`
        - removed the _old_ path
        """

        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown), [
            "What changed.",
            "The login flow now uses token checks.",
            "added a guard.",
            "removed the old path.",
        ])
    }

    func testCodeBlocksAreAnnouncedNotRead() {
        let markdown = """
        Here is the fix:

        ```swift
        let a = 1
        let b = 2
        ```

        Done.
        """

        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown), [
            "Here is the fix:",
            "2 line code block omitted.",
            "Done.",
        ])
    }

    func testUnterminatedCodeBlockStillAnnounced() {
        let markdown = "Streaming:\n```\nline one\nline two"
        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown).last, "2 line code block omitted.")
    }

    func testTablesAreOmitted() {
        let markdown = """
        Results:

        | a | b |
        |---|---|
        | 1 | 2 |

        All good.
        """

        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown), [
            "Results:",
            "Table omitted.",
            "All good.",
        ])
    }

    func testInlineCodeKeptWhenShortReplacedWhenLong() {
        let long = String(repeating: "x", count: 40)
        let markdown = "Run `swift build` after editing `\(long)`."
        XCTAssertEqual(
            SpeakableText.transform(markdown: markdown),
            "Run swift build after editing code."
        )
    }

    func testLinksURLsAndPathsBecomeSpeakable() {
        let markdown = "See [the docs](https://example.com/a/b) or https://github.com/x/y and Sources/BalaganApp/BoardScreen.swift for details."
        XCTAssertEqual(
            SpeakableText.transform(markdown: markdown),
            "See the docs or github.com and BoardScreen.swift for details."
        )
    }

    func testSentenceSplittingKeepsFilenamesAndDecimals() {
        let markdown = "The fix is in Board.swift and takes 1.5 seconds. Ship it! Ready?"
        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown), [
            "The fix is in Board.swift and takes 1.5 seconds.",
            "Ship it!",
            "Ready?",
        ])
    }

    func testSnakeCaseIdentifiersSurvive() {
        XCTAssertEqual(
            SpeakableText.transform(markdown: "The out_of_catalog flag is set."),
            "The out_of_catalog flag is set."
        )
    }

    func testHorizontalRulesAndImagesVanish() {
        let markdown = "Before.\n\n---\n\n![screenshot](img.png)\n\nAfter."
        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: markdown), ["Before.", "After."])
    }

    func testBlockquotesAreSpoken() {
        XCTAssertEqual(
            SpeakableText.transform(markdown: "> quoted advice here."),
            "quoted advice here."
        )
    }

    func testEmptyAndWhitespaceMarkdown() {
        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: ""), [])
        XCTAssertEqual(SpeakableText.sentences(fromMarkdown: "\n\n  \n"), [])
    }
}
