import Foundation

/// Tokens an agent session used, from its transcript, and what that would cost at API prices.
public struct TokenUsage: Equatable, Sendable {
    /// Input that wasn't served from the prompt cache.
    public var inputTokens = 0
    public var cacheWriteTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0
    /// API-equivalent cost in USD; nil when a model's price isn't known (e.g. Codex).
    public var costUSD: Double?
    /// The models that produced it ("claude-opus-5-5", "gpt-6.1-sol").
    public var models: Set<String> = []

    public init(
        inputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double? = nil,
        models: Set<String> = []
    ) {
        self.inputTokens = inputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.models = models
    }

    public var totalTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens }
    public var isEmpty: Bool { totalTokens == 0 }

    /// Several sessions (a task's tabs) added up. The cost is a sum of what's known: it stays nil only
    /// when no part had a price.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        let cost: Double? = (lhs.costUSD == nil && rhs.costUSD == nil) ? nil : (lhs.costUSD ?? 0) + (rhs.costUSD ?? 0)
        return TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            costUSD: cost,
            models: lhs.models.union(rhs.models)
        )
    }

    /// "1.2M", "340k", "820".
    public static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: tokens >= 10_000_000 ? "%.0fM" : "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...: return String(format: tokens >= 100_000 ? "%.0fk" : "%.1fk", Double(tokens) / 1_000)
        default: return "\(tokens)"
        }
    }
}

/// Anthropic API list prices, per million tokens, to estimate what a Claude session would cost on the
/// API. A subscription isn't billed per token; this is a yardstick for comparing tasks.
public enum ClaudePricing {
    public struct Rates: Equatable, Sendable {
        public var input: Double
        public var output: Double
        /// Cache reads differ by model (0.025× input on Fable 5.1, 0.05× on Opus 5.5, 0.1× elsewhere).
        public var cacheRead: Double
        public var cacheWrite5m: Double { input * 1.25 }
        public var cacheWrite1h: Double { input * 2 }
    }

    /// By model-id prefix, most specific first (so "claude-opus-5-5" isn't read as "claude-opus-5").
    static let table: [(prefix: String, rates: Rates)] = [
        ("claude-fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Rates(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", Rates(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Rates(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", Rates(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-4-5", Rates(input: 1, output: 5, cacheRead: 0.10)),
    ]

    public static func rates(for model: String) -> Rates? {
        let id = model.lowercased()
        return table.first { id == $0.prefix || id.hasPrefix($0.prefix + "-") || id.hasPrefix($0.prefix + "[") }?.rates
    }
}

/// Reads token usage out of an agent transcript, incrementally: feed it new lines as the file grows.
///
/// - **Claude** writes one `assistant` line per content block of a response, each repeating the
///   response's `usage`, so lines are de-duplicated by message id (the last copy wins).
/// - **Codex** logs a running total (`token_count` → `total_token_usage`), so the last one is the
///   session's usage. Its `input_tokens` includes the cached part.
public struct TranscriptTokenCounter: Sendable {
    public enum Format: Sendable { case claude, codex }

    public let format: Format
    /// Bytes of the file already consumed (the caller reads from here next time).
    public var offset: UInt64 = 0
    private var claudeMessages: [String: ClaudeMessageUsage] = [:]
    private var codexTotal: TokenUsage?
    private var codexModel: String?
    /// A trailing partial line, kept until its newline arrives.
    private var pending = ""

    struct ClaudeMessageUsage: Sendable {
        var model: String
        var input: Int
        var cacheWrite5m: Int
        var cacheWrite1h: Int
        var cacheRead: Int
        var output: Int
    }

    public init(format: Format) {
        self.format = format
    }

    public mutating func consume(_ data: Data) {
        offset += UInt64(data.count)
        let text = pending + String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        pending = lines.isEmpty ? "" : String(lines.removeLast())
        for line in lines where line.isEmpty == false {
            switch format {
            case .claude: consumeClaude(line)
            case .codex: consumeCodex(line)
            }
        }
    }

    public var usage: TokenUsage {
        switch format {
        case .codex:
            var usage = codexTotal ?? TokenUsage()
            if let codexModel { usage.models = [codexModel] }
            return usage
        case .claude:
            var total = TokenUsage(costUSD: nil)
            var cost = 0.0
            var priced = false
            for message in claudeMessages.values {
                total.inputTokens += message.input
                total.cacheWriteTokens += message.cacheWrite5m + message.cacheWrite1h
                total.cacheReadTokens += message.cacheRead
                total.outputTokens += message.output
                if message.model.isEmpty == false, message.model != "<synthetic>" { total.models.insert(message.model) }
                if let rates = ClaudePricing.rates(for: message.model) {
                    priced = true
                    cost += (Double(message.input) * rates.input
                        + Double(message.cacheWrite5m) * rates.cacheWrite5m
                        + Double(message.cacheWrite1h) * rates.cacheWrite1h
                        + Double(message.cacheRead) * rates.cacheRead
                        + Double(message.output) * rates.output) / 1_000_000
                }
            }
            total.costUSD = priced ? cost : nil
            return total
        }
    }

    private mutating func consumeClaude<S: StringProtocol>(_ line: S) {
        guard line.contains("\"usage\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let id = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        func int(_ key: String, in dictionary: [String: Any] = usage) -> Int { (dictionary[key] as? NSNumber)?.intValue ?? 0 }
        let creation = usage["cache_creation"] as? [String: Any]
        let write1h = creation.map { int("ephemeral_1h_input_tokens", in: $0) } ?? 0
        let writeTotal = int("cache_creation_input_tokens")
        claudeMessages[id] = ClaudeMessageUsage(
            model: message["model"] as? String ?? "",
            input: int("input_tokens"),
            cacheWrite5m: max(writeTotal - write1h, 0),
            cacheWrite1h: write1h,
            cacheRead: int("cache_read_input_tokens"),
            output: int("output_tokens")
        )
    }

    private mutating func consumeCodex<S: StringProtocol>(_ line: S) {
        if line.contains("\"turn_context\""),
           let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let model = (object["payload"] as? [String: Any])?["model"] as? String {
            codexModel = model
            return
        }
        guard line.contains("\"total_token_usage\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let info = (object["payload"] as? [String: Any])?["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }
        func int(_ key: String) -> Int { (total[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        codexTotal = TokenUsage(
            inputTokens: max(int("input_tokens") - cached, 0),
            cacheWriteTokens: int("cache_write_input_tokens"),
            cacheReadTokens: cached,
            outputTokens: int("output_tokens")
        )
    }
}
