import Foundation

/// What a task card says about its agent right now: which state it's in and for how long, what the
/// agent calls the work (its terminal-title summary), and the last thing it said.
///
/// Everything here is a pure projection of signals the app already has — the lifecycle map, the
/// `SET_TITLE`-fed `Surface.title`, and the on-disk transcript — so the board can show live state
/// without a single terminal-text read.
public struct TaskActivity: Equatable, Sendable {
    public var lifecycle: AgentLifecycle?
    /// When `lifecycle` last changed. Nil after a restart, before the agent reports anything.
    public var since: Date?
    /// The agent's own short name for the work (Claude's `✳ <summary>` title), if it set one.
    public var summary: String?
    /// A one-paragraph, markdown-free preview of the agent's latest prose.
    public var lastResponse: String?

    public init(lifecycle: AgentLifecycle?, since: Date?, summary: String?, lastResponse: String?) {
        self.lifecycle = lifecycle
        self.since = since
        self.summary = summary
        self.lastResponse = lastResponse
    }

    /// Nothing worth a row on the card.
    public var isEmpty: Bool {
        lifecycle == nil && summary == nil && lastResponse == nil
    }

    /// The last response is shown only once the agent has stopped. While it works, the previous
    /// turn's answer is stale and would read as the current state.
    public var visibleLastResponse: String? {
        lifecycle == .running ? nil : lastResponse
    }

    /// "Running 4m" / "Waiting 12m" / "Idle 1h 5m". Idle with no timestamp (a restored session that
    /// hasn't reported yet) says nothing rather than claim a state it can't back up.
    public func stateLabel(now: Date) -> String? {
        let word: String
        switch lifecycle {
        case .running: word = "Running"
        case .needsInput: word = "Waiting"
        case .idle: word = "Idle"
        case nil: return nil
        }
        guard let since else { return lifecycle == .idle ? nil : word }
        return "\(word) \(Self.elapsed(from: since, to: now))"
    }

    /// Compact elapsed time: "<1m", "4m", "1h 5m", "3d".
    public static func elapsed(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d"
    }

    // MARK: - Title summary

    /// Titles an agent (or the tab it lives in) shows before it has a real summary.
    private static let genericTitles: Set<String> = [
        "agent", "claude", "claude code", "codex", "shell", "terminal", "zsh", "bash",
    ]

    /// The agent's summary from a terminal title: Claude writes `✳ <summary>` when settled and
    /// `<spinner> <summary>` while working (the spinner is already stripped by the time a title is
    /// stored). Returns nil for a generic or redundant title so the card doesn't repeat itself.
    public static func summary(fromTitle title: String, taskTitle: String, cwd: String) -> String? {
        var text = AgentTitleHeuristic.strippingSpinner(title).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("✳") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.isEmpty == false else { return nil }
        let lowered = text.lowercased()
        if genericTitles.contains(lowered) { return nil }
        if lowered == taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() { return nil }
        let cwdName = URL(fileURLWithPath: cwd).lastPathComponent.lowercased()
        if cwdName.isEmpty == false, lowered == cwdName { return nil }
        return text
    }

    // MARK: - Response preview

    /// The last paragraph of an agent response as plain text: code fences dropped, markdown markers
    /// removed, whitespace collapsed, capped at `limit` characters. The end of a response is where an
    /// agent puts its conclusion or its question, which is what you want from a glance at the board.
    public static func responsePreview(fromMarkdown markdown: String, limit: Int = 240) -> String? {
        var paragraphs: [String] = []
        var current: [String] = []
        var inFence = false
        func flush() {
            if current.isEmpty == false { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                flush()
                continue
            }
            // Table rows read as noise in a one-line preview.
            if line.hasPrefix("|") { flush(); continue }
            current.append(plainInline(stripBlockMarker(line)))
        }
        flush()

        guard var text = paragraphs.last(where: { $0.isEmpty == false }) else { return nil }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.isEmpty == false else { return nil }
        if text.count > limit {
            text = String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    /// Drops a heading / quote / list marker from the start of a line.
    private static func stripBlockMarker(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == "#" || first == ">" {
            text = text.dropFirst().drop(while: { $0 == " " })
        }
        for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
            return String(text.dropFirst(marker.count))
        }
        // "1. " / "12) " ordered-list markers.
        let digits = text.prefix(while: \.isNumber)
        if digits.isEmpty == false {
            let rest = text.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        }
        return String(text)
    }

    /// Removes emphasis / code markers and reduces `[text](url)` links to their text.
    private static func plainInline(_ line: String) -> String {
        var text = line
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        }
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text
    }

    // MARK: - Primary surface

    /// One agent surface's facts, for picking which one a multi-tab task's card talks about.
    public struct Candidate: Equatable, Sendable {
        public var surfaceID: String
        public var lifecycle: AgentLifecycle?
        public var since: Date?
        public var isSelected: Bool

        public init(surfaceID: String, lifecycle: AgentLifecycle?, since: Date?, isSelected: Bool) {
            self.surfaceID = surfaceID
            self.lifecycle = lifecycle
            self.since = since
            self.isSelected = isSelected
        }
    }

    /// The surface a card should describe: one waiting on you beats one working (the thing you need to
    /// act on first), which beats a settled one; ties go to the most recent change, then to the
    /// workspace's selected tab, then to tab order.
    public static func primarySurface(among candidates: [Candidate]) -> String? {
        func rank(_ lifecycle: AgentLifecycle?) -> Int {
            switch lifecycle {
            case .needsInput: return 3
            case .running: return 2
            case .idle: return 1
            case nil: return 0
            }
        }
        let best = candidates.enumerated().max { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            if rank(l.lifecycle) != rank(r.lifecycle) { return rank(l.lifecycle) < rank(r.lifecycle) }
            if l.since != r.since { return (l.since ?? .distantPast) < (r.since ?? .distantPast) }
            if l.isSelected != r.isSelected { return r.isSelected }
            return lhs.offset > rhs.offset
        }
        return best?.element.surfaceID
    }
}

extension AgentTranscriptParser {
    /// The last assistant response in a transcript, reading only the file's tail — transcripts grow to
    /// many MB and a board refresh touches every task. Falls back to the whole file if the tail holds
    /// no prose (a long run of tool calls).
    public static func lastAssistantResponse(
        transcriptAt path: String,
        format: AgentTranscriptFormat,
        tailBytes: Int = 256 * 1024
    ) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8)
            ?? String(data: data.drop(while: { $0 & 0xC0 == 0x80 }), encoding: .utf8)
        else {
            return nil
        }
        // Mid-file start: the first line is partial.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        if let response = lastAssistantResponse(in: entries(fromJSONL: text, format: format)) {
            return response
        }
        guard start > 0, let whole = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return lastAssistantResponse(in: entries(fromJSONL: whole, format: format))
    }
}
