import Foundation
import XCTest
@testable import BalaganCore

final class AgentTranscriptParserTests: XCTestCase {
    // MARK: - Claude

    func testParsesClaudeConversation() {
        let jsonl = """
        {"type":"user","timestamp":"2026-06-15T22:18:18.798Z","message":{"role":"user","content":"Fix the login bug"}}
        {"type":"assistant","timestamp":"2026-06-15T22:18:19.155Z","message":{"content":[{"type":"thinking","thinking":"Let me check the auth flow"},{"type":"text","text":"Looking at the login flow now."},{"type":"tool_use","name":"Read","input":{"file_path":"/repo/Sources/Auth.swift"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"file contents"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Found it — the token check is inverted."}]}}
        """

        let entries = AgentTranscriptParser.entries(fromJSONL: jsonl, format: .claude)

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].kind, .user)
        XCTAssertEqual(entries[0].text, "Fix the login bug")
        XCTAssertEqual(entries[1].kind, .thinking)
        XCTAssertEqual(entries[2].kind, .assistant)
        XCTAssertEqual(entries[2].text, "Looking at the login flow now.")
        XCTAssertEqual(entries[3].kind, .toolUse(name: "Read"))
        XCTAssertEqual(entries[3].text, "/repo/Sources/Auth.swift")
        XCTAssertEqual(entries[4].kind, .assistant)
        XCTAssertNotNil(entries[0].timestamp)
        XCTAssertNotNil(entries[2].timestamp)
    }

    func testSkipsClaudeSidechainMetaAndNoiseRecords() {
        let jsonl = """
        {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent chatter"}]}}
        {"type":"user","isMeta":true,"message":{"content":"injected context"}}
        {"type":"user","message":{"content":"<system-reminder>recalled memory</system-reminder>"}}
        {"type":"user","message":{"content":"<command-name>/model</command-name>"}}
        {"type":"system","subtype":"info"}
        {"type":"ai-title","title":"whatever"}
        {"type":"user","message":{"content":"a real prompt"}}
        not json at all
        """

        let entries = AgentTranscriptParser.entries(fromJSONL: jsonl, format: .claude)

        XCTAssertEqual(entries.map(\.text), ["a real prompt"])
        XCTAssertEqual(entries[0].kind, .user)
    }

    func testClaudeToolUseDetailPrefersDescriptionAndTruncates() {
        let long = String(repeating: "x", count: 200)
        let jsonl = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls","description":"List files"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\(long)"}}]}}
        """

        let entries = AgentTranscriptParser.entries(fromJSONL: jsonl, format: .claude)

        XCTAssertEqual(entries[0].text, "List files")
        XCTAssertEqual(entries[1].text.count, 121)
        XCTAssertTrue(entries[1].text.hasSuffix("…"))
    }

    // MARK: - Codex

    func testParsesCodexConversation() {
        let jsonl = """
        {"timestamp":"2026-07-10T11:18:24.101Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>injected</user_instructions>"},{"type":"input_text","text":"run the tests"}]}}
        {"timestamp":"2026-07-10T11:18:25.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Planning the run"}],"encrypted_content":"..."}}
        {"timestamp":"2026-07-10T11:18:26.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"swift\\",\\"test\\"]}"}}
        {"timestamp":"2026-07-10T11:18:27.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const x = 1"}}
        {"timestamp":"2026-07-10T11:18:28.000Z","type":"response_item","payload":{"type":"agent_message","author":"/root/sub","content":[{"type":"input_text","text":"inter-agent traffic"}]}}
        {"timestamp":"2026-07-10T11:18:29.000Z","type":"event_msg","payload":{"type":"agent_message","message":"duplicate of response_item"}}
        {"timestamp":"2026-07-10T11:18:30.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"All 251 tests pass."}]}}
        """

        let entries = AgentTranscriptParser.entries(fromJSONL: jsonl, format: .codex)

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].kind, .user)
        XCTAssertEqual(entries[0].text, "run the tests")
        XCTAssertEqual(entries[1].kind, .thinking)
        XCTAssertEqual(entries[1].text, "Planning the run")
        XCTAssertEqual(entries[2].kind, .toolUse(name: "shell"))
        XCTAssertEqual(entries[3].kind, .toolUse(name: "exec"))
        XCTAssertEqual(entries[3].text, "const x = 1")
        XCTAssertEqual(entries[4].kind, .assistant)
        XCTAssertEqual(entries[4].text, "All 251 tests pass.")
        XCTAssertNotNil(entries[4].timestamp)
    }

    // MARK: - Tail buffer

    func testTailBufferCarriesPartialLinesAcrossChunks() {
        var buffer = TranscriptTailBuffer(format: .claude)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello world"}]}}"#

        let firstHalf = Data((line.prefix(30) as Substring).utf8)
        XCTAssertEqual(buffer.consume(firstHalf), [])

        let rest = Data((line.dropFirst(30) + "\n").utf8)
        let entries = buffer.consume(rest)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "Hello world")
        XCTAssertEqual(entries[0].id, "0.0")

        // Ids keep counting lines across chunks.
        let more = buffer.consume(Data((line + "\n").utf8))
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(more[0].id, "1.0")
    }

    func testTailBufferResetRestartsLineNumbering() {
        var buffer = TranscriptTailBuffer(format: .claude)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"# + "\n"
        _ = buffer.consume(Data(line.utf8))
        buffer.reset()
        let entries = buffer.consume(Data(line.utf8))
        XCTAssertEqual(entries.first?.id, "0.0")
    }

    // MARK: - Format inference

    func testInfersFormatFromAgentNameThenFilename() {
        XCTAssertEqual(AgentTranscriptFormat.infer(agentName: "claude", transcriptPath: nil), .claude)
        XCTAssertEqual(AgentTranscriptFormat.infer(agentName: "Codex", transcriptPath: nil), .codex)
        XCTAssertEqual(
            AgentTranscriptFormat.infer(agentName: nil, transcriptPath: "/x/rollout-2026-07-23-abc.jsonl"),
            .codex
        )
        XCTAssertEqual(
            AgentTranscriptFormat.infer(agentName: nil, transcriptPath: "/x/projects/p/session.jsonl"),
            .claude
        )
    }

    // MARK: - Last assistant response

    func testLastAssistantResponseJoinsTrailingProse() {
        let entries = [
            TranscriptEntry(id: "0", kind: .user, text: "do the thing"),
            TranscriptEntry(id: "1", kind: .assistant, text: "Older answer."),
            TranscriptEntry(id: "2", kind: .user, text: "and now?"),
            TranscriptEntry(id: "3", kind: .toolUse(name: "Bash"), text: "swift test"),
            TranscriptEntry(id: "4", kind: .assistant, text: "First paragraph."),
            TranscriptEntry(id: "5", kind: .thinking, text: "hmm"),
            TranscriptEntry(id: "6", kind: .assistant, text: "Second paragraph."),
        ]

        XCTAssertEqual(
            AgentTranscriptParser.lastAssistantResponse(in: entries),
            "First paragraph.\n\nSecond paragraph."
        )
    }

    func testLastAssistantResponseMidRunFallsBackToProseBeforeToolCalls() {
        let entries = [
            TranscriptEntry(id: "0", kind: .user, text: "go"),
            TranscriptEntry(id: "1", kind: .assistant, text: "Let me check the tests."),
            TranscriptEntry(id: "2", kind: .toolUse(name: "Bash"), text: "swift test"),
            TranscriptEntry(id: "3", kind: .toolUse(name: "Read"), text: "file.swift"),
        ]

        XCTAssertEqual(
            AgentTranscriptParser.lastAssistantResponse(in: entries),
            "Let me check the tests."
        )
    }

    func testLastAssistantResponseNilWhenNoAssistantProseInFinalTurn() {
        XCTAssertNil(AgentTranscriptParser.lastAssistantResponse(in: []))
        XCTAssertNil(AgentTranscriptParser.lastAssistantResponse(in: [
            TranscriptEntry(id: "0", kind: .assistant, text: "Old."),
            TranscriptEntry(id: "1", kind: .user, text: "new prompt, no answer yet"),
        ]))
    }
}
