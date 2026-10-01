import Foundation

/// One normalized conversation entry, agent-agnostic (the Vibe-Kanban pattern): reader mode and
/// speak-last-response render these instead of raw terminal text or per-agent JSON.
public struct TranscriptEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case user
        case assistant
        case toolUse(name: String)
        case thinking
    }

    /// Stable across incremental re-parses: derived from the JSONL line index + block index.
    public var id: String
    public var kind: Kind
    /// Markdown for user/assistant, a compact one-line detail for toolUse, the (possibly empty)
    /// summary for thinking.
    public var text: String
    public var timestamp: Date?

    public init(id: String, kind: Kind, text: String, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

public enum AgentTranscriptFormat: String, Equatable, Sendable {
    case claude
    case codex

    /// Prefer the binding's agent name; fall back to the Codex rollout filename convention.
    public static func infer(agentName: String?, transcriptPath: String?) -> AgentTranscriptFormat {
        switch agentName?.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default:
            let filename = transcriptPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return filename.hasPrefix("rollout-") ? .codex : .claude
        }
    }
}

/// Parses agent session transcripts (line-delimited JSON) into `TranscriptEntry` values.
/// Line-oriented so a tailer can feed only appended lines; malformed lines are skipped silently
/// (transcripts are written concurrently and the last line may be partial).
public enum AgentTranscriptParser {
    public static func entries(fromJSONL text: String, format: AgentTranscriptFormat) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        var lineIndex = 0
        text.enumerateLines { line, _ in
            result.append(contentsOf: entries(fromLine: line, lineIndex: lineIndex, format: format))
            lineIndex += 1
        }
        return result
    }

    public static func entries(
        fromLine line: String,
        lineIndex: Int,
        format: AgentTranscriptFormat
    ) -> [TranscriptEntry] {
        guard line.isEmpty == false,
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        else {
            return []
        }
        switch format {
        case .claude: return claudeEntries(record: object, lineIndex: lineIndex)
        case .codex: return codexEntries(record: object, lineIndex: lineIndex)
        }
    }

    /// The agent's most recent prose: walking back from the end, the last contiguous run of
    /// assistant text — never crossing a user prompt, ignoring thinking, and stopping at a tool
    /// call only once some prose was found (so a mid-run transcript that ends in tool calls yields
    /// the last thing the agent actually said).
    public static func lastAssistantResponse(in entries: [TranscriptEntry]) -> String? {
        var collected: [String] = []
        for entry in entries.reversed() {
            switch entry.kind {
            case .assistant:
                collected.append(entry.text)
            case .thinking:
                continue
            case .toolUse:
                if collected.isEmpty { continue }
                return joinedResponse(collected)
            case .user:
                return joinedResponse(collected)
            }
        }
        return joinedResponse(collected)
    }

    private static func joinedResponse(_ reversedTexts: [String]) -> String? {
        guard reversedTexts.isEmpty == false else { return nil }
        return reversedTexts.reversed().joined(separator: "\n\n")
    }

    // MARK: - Claude (~/.claude/projects/<slug>/<session-id>.jsonl)

    /// User-record text injected by the harness rather than typed by the user.
    private static let claudeNoiseMarkers = [
        "<command-name>",
        "<local-command-stdout>",
        "<local-command-caveat>",
        "<system-reminder>",
        "<task-notification>",
        "Caveat: The messages below",
    ]

    private static func claudeEntries(record: [String: Any], lineIndex: Int) -> [TranscriptEntry] {
        guard let type = record["type"] as? String, type == "assistant" || type == "user" else {
            return []
        }
        // Sidechains are subagent traffic; meta records are harness-injected context.
        if (record["isSidechain"] as? Bool) == true || (record["isMeta"] as? Bool) == true {
            return []
        }
        guard let message = record["message"] as? [String: Any] else { return [] }
        let timestamp = (record["timestamp"] as? String).flatMap(parseTimestamp)

        if type == "user" {
            return claudeUserEntries(message: message, lineIndex: lineIndex, timestamp: timestamp)
        }

        guard let content = message["content"] as? [[String: Any]] else { return [] }
        var entries: [TranscriptEntry] = []
        for (blockIndex, block) in content.enumerated() {
            let id = "\(lineIndex).\(blockIndex)"
            switch block["type"] as? String {
            case "text":
                if let text = (block["text"] as? String)?.nilIfBlank {
                    entries.append(TranscriptEntry(id: id, kind: .assistant, text: text, timestamp: timestamp))
                }
            case "thinking":
                let text = (block["thinking"] as? String) ?? ""
                entries.append(TranscriptEntry(id: id, kind: .thinking, text: text, timestamp: timestamp))
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let detail = toolUseDetail(input: block["input"] as? [String: Any])
                entries.append(TranscriptEntry(id: id, kind: .toolUse(name: name), text: detail, timestamp: timestamp))
            default:
                break
            }
        }
        return entries
    }

    private static func claudeUserEntries(
        message: [String: Any],
        lineIndex: Int,
        timestamp: Date?
    ) -> [TranscriptEntry] {
        var texts: [String] = []
        if let text = message["content"] as? String {
            texts = [text]
        } else if let content = message["content"] as? [[String: Any]] {
            // tool_result / image blocks are tool traffic, not the user speaking.
            texts = content.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }
        }
        return texts.enumerated().compactMap { blockIndex, text in
            guard let text = text.nilIfBlank, isClaudeNoise(text) == false else { return nil }
            return TranscriptEntry(id: "\(lineIndex).\(blockIndex)", kind: .user, text: text, timestamp: timestamp)
        }
    }

    private static func isClaudeNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return claudeNoiseMarkers.contains { trimmed.hasPrefix($0) }
    }

    /// A compact, single-line summary of a tool invocation for the collapsed tool chip.
    private static func toolUseDetail(input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["description", "command", "file_path", "path", "pattern", "prompt", "query", "url"] {
            if let value = (input[key] as? String)?.nilIfBlank {
                return compactDetail(value)
            }
        }
        return ""
    }

    // MARK: - Codex (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<session-id>.jsonl)

    /// User input_text injected by the harness rather than typed by the user.
    private static let codexNoiseMarkers = [
        "<environment_context>",
        "<user_instructions>",
        "<turn_context>",
    ]

    private static func codexEntries(record: [String: Any], lineIndex: Int) -> [TranscriptEntry] {
        // event_msg records duplicate response_item content (and add telemetry like token_count);
        // response_item is the durable form.
        guard record["type"] as? String == "response_item",
              let payload = record["payload"] as? [String: Any]
        else {
            return []
        }
        let timestamp = (record["timestamp"] as? String).flatMap(parseTimestamp)

        switch payload["type"] as? String {
        case "message":
            return codexMessageEntries(payload: payload, lineIndex: lineIndex, timestamp: timestamp)
        case "reasoning":
            let summaries = (payload["summary"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String } ?? []
            let text = summaries.joined(separator: "\n\n")
            return [TranscriptEntry(id: "\(lineIndex).0", kind: .thinking, text: text, timestamp: timestamp)]
        case "function_call", "custom_tool_call":
            let name = (payload["name"] as? String) ?? "tool"
            let detail = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
            return [TranscriptEntry(
                id: "\(lineIndex).0",
                kind: .toolUse(name: name),
                text: compactDetail(detail),
                timestamp: timestamp
            )]
        default:
            // agent_message is inter-agent (subagent) traffic — Codex's sidechain equivalent.
            return []
        }
    }

    private static func codexMessageEntries(
        payload: [String: Any],
        lineIndex: Int,
        timestamp: Date?
    ) -> [TranscriptEntry] {
        guard let role = payload["role"] as? String,
              let content = payload["content"] as? [[String: Any]]
        else {
            return []
        }
        var entries: [TranscriptEntry] = []
        for (blockIndex, block) in content.enumerated() {
            let id = "\(lineIndex).\(blockIndex)"
            let blockType = block["type"] as? String
            guard let text = (block["text"] as? String)?.nilIfBlank else { continue }
            if role == "assistant", blockType == "output_text" {
                entries.append(TranscriptEntry(id: id, kind: .assistant, text: text, timestamp: timestamp))
            } else if role == "user", blockType == "input_text", isCodexNoise(text) == false {
                entries.append(TranscriptEntry(id: id, kind: .user, text: text, timestamp: timestamp))
            }
        }
        return entries
    }

    private static func isCodexNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return codexNoiseMarkers.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - Shared

    private static func compactDetail(_ value: String, limit: Int = 120) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    /// Transcript timestamps are ISO8601, with fractional seconds in Claude's case.
    private static func parseTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
