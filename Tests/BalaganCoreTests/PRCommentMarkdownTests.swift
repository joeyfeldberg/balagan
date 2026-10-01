import XCTest
@testable import BalaganCore

final class PRCommentMarkdownTests: XCTestCase {
    func testHeadingsBulletsAndParagraphs() {
        let blocks = PRCommentMarkdown.blocks(from: """
        ## Pull request overview

        Enables the Librarian to answer questions.

        - first point
        - second point
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Pull request overview"),
            .paragraph("Enables the Librarian to answer questions."),
            .bullet(depth: 0, text: "first point"),
            .bullet(depth: 0, text: "second point"),
        ])
    }

    func testTableCollapsesToRowCount() {
        let blocks = PRCommentMarkdown.blocks(from: """
        ## Coverage Report

        | Category | Percentage |
        |-----------|------------|
        | Total Coverage | 80% |
        | Files | 90% |
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Coverage Report"),
            .table(rows: 2),
        ])
    }

    func testEmojiShortcodesMapped() {
        let blocks = PRCommentMarkdown.blocks(from: "Coverage :bar_chart: looks :white_check_mark:")
        XCTAssertEqual(blocks, [.paragraph("Coverage 📊 looks ✅")])
    }

    func testFencedCodeBlockPreserved() {
        let blocks = PRCommentMarkdown.blocks(from: """
        Run:

        ```
        swift test
        make lint
        ```
        """)
        XCTAssertEqual(blocks, [.paragraph("Run:"), .code("swift test\nmake lint")])
    }

    func testHTMLCommentsAndTagsStripped() {
        let blocks = PRCommentMarkdown.blocks(from: "<!-- machine marker -->Real text<br/> here")
        XCTAssertEqual(blocks, [.paragraph("Real text here")])
    }

    func testBlockquoteAndRule() {
        let blocks = PRCommentMarkdown.blocks(from: """
        > quoted line

        ---
        """)
        XCTAssertEqual(blocks, [.quote("quoted line"), .rule])
    }

    func testSynopsisPrefersHeadingThenParagraph() {
        XCTAssertEqual(PRCommentMarkdown.synopsis(from: "## Overview\n\nbody"), "Overview")
        XCTAssertEqual(PRCommentMarkdown.synopsis(from: "just a body\nmore"), "just a body more")
        XCTAssertEqual(PRCommentMarkdown.synopsis(from: "<!-- only marker -->"), "(no text)")
    }
}

final class PRAuthorAndActivityTests: XCTestCase {
    func testBotDetection() {
        for bot in ["github-actions[bot]", "dependabot[bot]", "copilot-pull-request-reviewer",
                    "github-actions", "renovate[bot]", "codecov", "some-bot", "mybot"] {
            XCTAssertTrue(PRAuthor.isBot(bot), "\(bot) should be a bot")
        }
        for human in ["joeyfeldberg", "octocat", "alice", "bob123"] {
            XCTAssertFalse(PRAuthor.isBot(human), "\(human) should not be a bot")
        }
    }

    func testRelativeTime() {
        let now = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        XCTAssertEqual(relativePRTime(fromISO: "2026-07-17T11:59:30Z", relativeTo: now), "just now")
        XCTAssertEqual(relativePRTime(fromISO: "2026-07-17T11:30:00Z", relativeTo: now), "30m ago")
        XCTAssertEqual(relativePRTime(fromISO: "2026-07-17T09:00:00Z", relativeTo: now), "3h ago")
        XCTAssertEqual(relativePRTime(fromISO: "2026-07-15T12:00:00Z", relativeTo: now), "2d ago")
        XCTAssertEqual(relativePRTime(fromISO: "", relativeTo: now), "")
    }

    func testActivityMergesAndSortsChronologically() {
        let pr = TaskPullRequest(
            number: 1, title: "t", url: "u", state: .open, isDraft: false, reviewDecision: nil,
            checks: [],
            comments: [PRComment(author: "alice", body: "second", createdAt: "2026-07-15T11:00:00Z", url: "c")],
            reviews: [PRReview(author: "bob", state: "APPROVED", body: "first", submittedAt: "2026-07-15T10:00:00Z", url: "r")]
        )
        let activity = pr.activity
        XCTAssertEqual(activity.map(\.body), ["first", "second"])   // oldest → newest
        XCTAssertEqual(activity.first?.reviewState, "APPROVED")
        XCTAssertNil(activity.last?.reviewState)
    }

    func testActivityIncludesInlineCodeComments() {
        let pr = TaskPullRequest(
            number: 1, title: "t", url: "u", state: .open, isDraft: false, reviewDecision: nil,
            checks: [], comments: [], reviews: [],
            reviewComments: [
                PRReviewComment(author: "copilot", body: "fix nil", path: "a/File.swift", line: 42,
                                createdAt: "2026-07-15T12:00:00Z", url: "rc1"),
            ]
        )
        let item = pr.activity.first
        XCTAssertEqual(item?.codeLocation, "File.swift:42")
        XCTAssertEqual(item?.body, "fix nil")
    }
}
