import XCTest
@testable import BalaganCore

final class TaskTokensTests: XCTestCase {
    private func claudeLine(id: String, model: String = "claude-opus-5-5", input: Int = 0, write5m: Int = 0, write1h: Int = 0, read: Int = 0, output: Int, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write5m + write1h),"cache_read_input_tokens":\#(read),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)}}}}"#
    }

    func testClaudeCountsEachResponseOnceAndPricesIt() {
        // Claude repeats a response's usage on every content-block line; the last copy counts.
        let lines = [
            claudeLine(id: "m1", input: 10, write1h: 1_000_000, read: 0, output: 100),
            claudeLine(id: "m1", input: 10, write1h: 1_000_000, read: 0, output: 1_000_000),
            claudeLine(id: "m2", read: 1_000_000, output: 0),
            claudeLine(id: "sub", output: 999_999, sidechain: true),
            #"{"type":"user","message":{"content":"hi"}}"#,
        ]
        var counter = TranscriptTokenCounter(format: .claude)
        counter.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        let usage = counter.usage
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.cacheWriteTokens, 1_000_000)
        XCTAssertEqual(usage.cacheReadTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 1_000_000, "the duplicate and the subagent line don't add")
        // Opus 5.5: 1M 1h-writes at 2×$4 + 1M reads at $0.20 + 1M output at $20 + 10 input at $4/M.
        XCTAssertEqual(usage.costUSD ?? 0, 8 + 0.20 + 20 + 0.00004, accuracy: 0.0001)
        XCTAssertEqual(usage.models, ["claude-opus-5-5"])
    }

    func testReadsIncrementallyAcrossSplitLines() {
        let text = claudeLine(id: "a", output: 5) + "\n" + claudeLine(id: "b", output: 7) + "\n"
        let data = Data(text.utf8)
        var counter = TranscriptTokenCounter(format: .claude)
        counter.consume(data.prefix(40))
        XCTAssertEqual(counter.usage.outputTokens, 0)
        counter.consume(data.dropFirst(40))
        XCTAssertEqual(counter.usage.outputTokens, 12)
        XCTAssertEqual(counter.offset, UInt64(data.count))
    }

    func testCodexTakesTheLastRunningTotalAndSplitsOutTheCachedInput() {
        let lines = [
            #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":5}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50}}}}"#,
        ]
        var counter = TranscriptTokenCounter(format: .codex)
        counter.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        let usage = counter.usage
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 900)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertNil(usage.costUSD, "no price table for Codex")
        XCTAssertEqual(usage.models, ["gpt-6.1-sol"])
    }

    func testPricesMatchByModelPrefixAndSumAcrossTabs() {
        XCTAssertEqual(ClaudePricing.rates(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(ClaudePricing.rates(for: "claude-opus-5")?.input, 5, "not mistaken for Opus 5.5")
        XCTAssertEqual(ClaudePricing.rates(for: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(ClaudePricing.rates(for: "claude-sonnet-4-6[1m]")?.output, 15)
        XCTAssertNil(ClaudePricing.rates(for: "gpt-6.1-sol"))

        let sum = TokenUsage(outputTokens: 10, costUSD: 1.5) + TokenUsage(outputTokens: 5) + TokenUsage(outputTokens: 1, costUSD: 0.5)
        XCTAssertEqual(sum.outputTokens, 16)
        XCTAssertEqual(sum.costUSD, 2.0)
        XCTAssertNil((TokenUsage(outputTokens: 1) + TokenUsage(outputTokens: 1)).costUSD)
        XCTAssertEqual(TokenUsage.compact(314_000_000), "314M")
        XCTAssertEqual(TokenUsage.compact(1_250_000), "1.2M")
        XCTAssertEqual(TokenUsage.compact(42_500), "42.5k")
    }
}
