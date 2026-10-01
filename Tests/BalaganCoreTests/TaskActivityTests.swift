import XCTest
@testable import BalaganCore

final class TaskActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - State label

    func testStateLabelNamesTheStateAndHowLong() {
        let running = TaskActivity(lifecycle: .running, since: t0, summary: nil, lastResponse: nil)
        XCTAssertEqual(running.stateLabel(now: t0.addingTimeInterval(4 * 60 + 30)), "Running 4m")

        let waiting = TaskActivity(lifecycle: .needsInput, since: t0, summary: nil, lastResponse: nil)
        XCTAssertEqual(waiting.stateLabel(now: t0.addingTimeInterval(20)), "Waiting <1m")

        let idle = TaskActivity(lifecycle: .idle, since: t0, summary: nil, lastResponse: nil)
        XCTAssertEqual(idle.stateLabel(now: t0.addingTimeInterval(65 * 60)), "Idle 1h 5m")
    }

    func testStateLabelWithoutATimestamp() {
        // A restored, not-yet-reporting session: idle can't be backed up, so say nothing.
        XCTAssertNil(TaskActivity(lifecycle: .idle, since: nil, summary: nil, lastResponse: nil).stateLabel(now: t0))
        XCTAssertEqual(TaskActivity(lifecycle: .running, since: nil, summary: nil, lastResponse: nil).stateLabel(now: t0), "Running")
        XCTAssertNil(TaskActivity(lifecycle: nil, since: t0, summary: nil, lastResponse: nil).stateLabel(now: t0))
    }

    func testElapsedFormatting() {
        XCTAssertEqual(TaskActivity.elapsed(from: t0, to: t0.addingTimeInterval(-30)), "<1m")
        XCTAssertEqual(TaskActivity.elapsed(from: t0, to: t0.addingTimeInterval(59 * 60)), "59m")
        XCTAssertEqual(TaskActivity.elapsed(from: t0, to: t0.addingTimeInterval(2 * 3600)), "2h")
        XCTAssertEqual(TaskActivity.elapsed(from: t0, to: t0.addingTimeInterval(3 * 86400 + 5)), "3d")
    }

    func testLastResponseIsHiddenWhileRunning() {
        var activity = TaskActivity(lifecycle: .running, since: t0, summary: nil, lastResponse: "Done.")
        XCTAssertNil(activity.visibleLastResponse)
        activity.lifecycle = .needsInput
        XCTAssertEqual(activity.visibleLastResponse, "Done.")
        activity.lifecycle = nil
        XCTAssertEqual(activity.visibleLastResponse, "Done.")
    }

    // MARK: - Summary

    func testSummaryStripsClaudeMarkers() {
        XCTAssertEqual(TaskActivity.summary(fromTitle: "✳ Fix flaky deadline test", taskTitle: "Tests", cwd: "/r/x"),
                       "Fix flaky deadline test")
        XCTAssertEqual(TaskActivity.summary(fromTitle: "◐ Fix flaky deadline test", taskTitle: "Tests", cwd: "/r/x"),
                       "Fix flaky deadline test")
    }

    func testSummaryDropsGenericAndRedundantTitles() {
        XCTAssertNil(TaskActivity.summary(fromTitle: "✳ Claude Code", taskTitle: "T", cwd: "/r/x"))
        XCTAssertNil(TaskActivity.summary(fromTitle: "agent", taskTitle: "T", cwd: "/r/x"))
        XCTAssertNil(TaskActivity.summary(fromTitle: "  ", taskTitle: "T", cwd: "/r/x"))
        XCTAssertNil(TaskActivity.summary(fromTitle: "Build kanban shell", taskTitle: "build kanban shell", cwd: "/r/x"))
        XCTAssertNil(TaskActivity.summary(fromTitle: "tasks", taskTitle: "T", cwd: "/repos/private/tasks"))
    }

    // MARK: - Response preview

    func testPreviewTakesTheLastParagraphAsPlainText() {
        let markdown = """
        ## Summary

        I fixed the **deadline** handling in `Deadline.swift`.

        ```swift
        let x = 1
        ```

        - Want me to also update [the docs](https://example.com)?
        """
        XCTAssertEqual(TaskActivity.responsePreview(fromMarkdown: markdown),
                       "Want me to also update the docs?")
    }

    func testPreviewJoinsAParagraphsLinesAndCapsLength() {
        XCTAssertEqual(TaskActivity.responsePreview(fromMarkdown: "One line\nand   another."), "One line and another.")
        let long = String(repeating: "word ", count: 100)
        let preview = TaskActivity.responsePreview(fromMarkdown: long, limit: 40)
        XCTAssertEqual(preview?.count, 40)
        XCTAssertEqual(preview?.hasSuffix("…"), true)
    }

    func testPreviewOfOnlyCodeOrTablesIsNil() {
        XCTAssertNil(TaskActivity.responsePreview(fromMarkdown: "```\ncode\n```"))
        XCTAssertNil(TaskActivity.responsePreview(fromMarkdown: "| a | b |\n|---|---|"))
        XCTAssertNil(TaskActivity.responsePreview(fromMarkdown: ""))
    }

    func testPreviewStripsOrderedListAndQuoteMarkers() {
        XCTAssertEqual(TaskActivity.responsePreview(fromMarkdown: "1. Run the tests"), "Run the tests")
        XCTAssertEqual(TaskActivity.responsePreview(fromMarkdown: "> quoted"), "quoted")
    }

    // MARK: - Primary surface

    func testPrimarySurfacePrefersWaitingThenRunning() {
        let pick = TaskActivity.primarySurface(among: [
            .init(surfaceID: "a", lifecycle: .running, since: t0.addingTimeInterval(10), isSelected: true),
            .init(surfaceID: "b", lifecycle: .needsInput, since: t0, isSelected: false),
            .init(surfaceID: "c", lifecycle: .idle, since: t0.addingTimeInterval(20), isSelected: false),
        ])
        XCTAssertEqual(pick, "b")
    }

    func testPrimarySurfaceTieBreaksOnRecencyThenSelectionThenOrder() {
        XCTAssertEqual(TaskActivity.primarySurface(among: [
            .init(surfaceID: "a", lifecycle: .idle, since: t0, isSelected: false),
            .init(surfaceID: "b", lifecycle: .idle, since: t0.addingTimeInterval(5), isSelected: false),
        ]), "b")
        XCTAssertEqual(TaskActivity.primarySurface(among: [
            .init(surfaceID: "a", lifecycle: nil, since: nil, isSelected: false),
            .init(surfaceID: "b", lifecycle: nil, since: nil, isSelected: true),
        ]), "b")
        XCTAssertEqual(TaskActivity.primarySurface(among: [
            .init(surfaceID: "a", lifecycle: nil, since: nil, isSelected: false),
            .init(surfaceID: "b", lifecycle: nil, since: nil, isSelected: false),
        ]), "a")
        XCTAssertNil(TaskActivity.primarySurface(among: []))
    }

    // MARK: - Transcript tail

    func testLastResponseFromTranscriptTail() throws {
        let path = NSTemporaryDirectory() + "task-activity-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        func assistant(_ text: String) -> String {
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
        }
        // Enough padding before the answer that the tail read starts mid-file on a partial line.
        let filler = (0..<200).map { _ in assistant(String(repeating: "x", count: 50)) }
        let lines = filler + [#"{"type":"user","message":{"role":"user","content":"go"}}"#, assistant("All green.")]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            AgentTranscriptParser.lastAssistantResponse(transcriptAt: path, format: .claude, tailBytes: 500),
            "All green."
        )
        XCTAssertNil(AgentTranscriptParser.lastAssistantResponse(transcriptAt: path + ".missing", format: .claude))
    }
}
