import XCTest
@testable import BalaganCore

final class GitHubPRStatusParserTests: XCTestCase {
    private func parse(_ json: String) -> TaskPullRequest? {
        GitHubPRStatusParser.pullRequest(fromViewJSON: Data(json.utf8))
    }

    func testParsesCoreFieldsAndActionsChecks() {
        let pr = parse(#"""
        {
          "number": 42,
          "title": "Add sleep",
          "url": "https://github.com/o/r/pull/42",
          "state": "OPEN",
          "isDraft": true,
          "reviewDecision": "REVIEW_REQUIRED",
          "statusCheckRollup": [
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://x/build"},
            {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://x/test"}
          ],
          "comments": [],
          "reviews": []
        }
        """#)
        XCTAssertEqual(pr?.number, 42)
        XCTAssertEqual(pr?.title, "Add sleep")
        XCTAssertEqual(pr?.state, .open)
        XCTAssertEqual(pr?.isDraft, true)
        XCTAssertEqual(pr?.reviewDecision, "REVIEW_REQUIRED")
        XCTAssertEqual(pr?.checks.count, 2)
        XCTAssertEqual(pr?.checks.first?.state, .success)
        XCTAssertEqual(pr?.checks.last?.state, .pending)  // not COMPLETED → pending
        XCTAssertEqual(pr?.rollup, .pending)              // any pending (no failures) → pending
    }

    func testFailureRollupWinsOverPending() {
        let pr = parse(#"""
        {"number":1,"url":"u","state":"OPEN","statusCheckRollup":[
          {"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},
          {"__typename":"CheckRun","name":"b","status":"QUEUED"},
          {"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"SUCCESS"}
        ]}
        """#)
        XCTAssertEqual(pr?.rollup, .failure)
        XCTAssertEqual(pr?.failedCount, 1)
        XCTAssertEqual(pr?.passedCount, 1)
        XCTAssertEqual(pr?.pendingCount, 1)
    }

    func testNeutralAndSkippedDoNotBlockSuccess() {
        let pr = parse(#"""
        {"number":1,"url":"u","state":"OPEN","statusCheckRollup":[
          {"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SKIPPED"},
          {"__typename":"CheckRun","name":"c","status":"COMPLETED","conclusion":"NEUTRAL"}
        ]}
        """#)
        XCTAssertEqual(pr?.rollup, .success)
    }

    func testLegacyStatusContextShape() {
        let pr = parse(#"""
        {"number":7,"url":"u","state":"OPEN","statusCheckRollup":[
          {"__typename":"StatusContext","context":"ci/circleci","state":"FAILURE","targetUrl":"https://ci/1"}
        ]}
        """#)
        XCTAssertEqual(pr?.checks.first?.name, "ci/circleci")
        XCTAssertEqual(pr?.checks.first?.state, .failure)
        XCTAssertEqual(pr?.checks.first?.url, "https://ci/1")
        XCTAssertEqual(pr?.rollup, .failure)
    }

    func testNoChecksRollupIsNone() {
        let pr = parse(#"{"number":1,"url":"u","state":"OPEN","statusCheckRollup":[]}"#)
        XCTAssertEqual(pr?.rollup, CIState.noChecks)
    }

    func testMergedAndClosedStates() {
        XCTAssertEqual(parse(#"{"number":1,"url":"u","state":"MERGED"}"#)?.state, .merged)
        XCTAssertEqual(parse(#"{"number":1,"url":"u","state":"CLOSED"}"#)?.state, .closed)
    }

    func testCommentsAndReviews() {
        let pr = parse(#"""
        {
          "number": 9, "url": "u", "state": "OPEN",
          "comments": [
            {"author":{"login":"alice"},"body":"looks good","createdAt":"2026-07-15T10:00:00Z","url":"c1"},
            {"author":{"login":"bob"},"body":"","createdAt":"2026-07-15T11:00:00Z"}
          ],
          "reviews": [
            {"author":{"login":"carol"},"state":"CHANGES_REQUESTED","body":"fix this","submittedAt":"t","url":"r1"},
            {"author":{"login":"dave"},"state":"APPROVED","body":"","submittedAt":"t"},
            {"author":{"login":"eve"},"state":"COMMENTED","body":"","submittedAt":"t"}
          ]
        }
        """#)
        // Empty-body comment dropped; empty COMMENTED review dropped; approve-with-no-body kept.
        XCTAssertEqual(pr?.comments.count, 1)
        XCTAssertEqual(pr?.comments.first?.author, "alice")
        XCTAssertEqual(pr?.reviews.count, 2)
        XCTAssertEqual(pr?.reviews.first?.state, "CHANGES_REQUESTED")
        // commentCount = 1 comment + 1 review with a body (the approve has none).
        XCTAssertEqual(pr?.commentCount, 2)
    }

    func testListJSONPicksFirstOpenPR() {
        let pr = GitHubPRStatusParser.firstPullRequest(fromListJSON: Data(#"""
        [
          {"number":1,"url":"u1","state":"CLOSED"},
          {"number":2,"url":"u2","state":"OPEN"}
        ]
        """#.utf8))
        XCTAssertEqual(pr?.number, 2)
    }

    func testReviewCommentsFromRESTAPI() {
        // Mirrors the real GET /pulls/{n}/comments shape: `user` (not `author`), line may be null with
        // original_line set, html_url.
        let comments = GitHubPRStatusParser.reviewComments(fromAPIJSON: Data(#"""
        [
          {"user":{"login":"copilot-pull-request-reviewer"},"body":"nil cart can slip through","path":"Sources/Agent/CartLookup.swift","line":42,"html_url":"https://x/rc1","created_at":"2026-07-15T12:05:00Z"},
          {"user":{"login":"tommaso"},"body":"reworded","path":"pkg/cmd/publish.go","line":null,"original_line":109,"html_url":"https://x/rc2","created_at":"2026-07-17T00:00:00Z"},
          {"user":{"login":"x"},"body":"","path":"a","html_url":"h","created_at":"t"}
        ]
        """#.utf8))
        XCTAssertEqual(comments.count, 2)  // empty-body dropped
        XCTAssertEqual(comments[0].author, "copilot-pull-request-reviewer")
        XCTAssertEqual(comments[0].location, "CartLookup.swift:42")
        XCTAssertEqual(comments[1].line, 109)  // fell back to original_line
        XCTAssertEqual(comments[1].location, "publish.go:109")
    }

    func testMalformedOrEmptyReturnsNil() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse("{}"))  // no number/url
        XCTAssertNil(GitHubPRStatusParser.firstPullRequest(fromListJSON: Data("[]".utf8)))
    }
}
