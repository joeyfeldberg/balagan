import Foundation

/// Converts agent-response markdown into text a speech synthesizer can read aloud.
///
/// The rules follow the consistent lessons of every read-aloud precedent: never speak raw
/// markdown, never read code or URLs verbatim, and prefer short sentence-sized units (the
/// synthesizer queues one utterance per sentence so playback can skip and pause cleanly).
public enum SpeakableText {
    /// Sentence-sized speakable units, in reading order.
    public static func sentences(fromMarkdown markdown: String) -> [String] {
        paragraphs(fromMarkdown: markdown).flatMap(splitIntoSentences)
    }

    /// The full speakable text as one string (the `--dry-run` / preview form).
    public static func transform(markdown: String) -> String {
        sentences(fromMarkdown: markdown).joined(separator: " ")
    }

    // MARK: - Block pass

    private static func paragraphs(fromMarkdown markdown: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var fenceLineCount: Int?
        var inTable = false

        func flush() {
            if current.isEmpty == false {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let count = fenceLineCount {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    flush()
                    paragraphs.append(count == 1 ? "1 line code block omitted." : "\(count) line code block omitted.")
                    fenceLineCount = nil
                } else {
                    fenceLineCount = count + 1
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenceLineCount = 0
                continue
            }

            if line.hasPrefix("|") {
                if inTable == false {
                    flush()
                    paragraphs.append("Table omitted.")
                    inTable = true
                }
                continue
            }
            inTable = false

            if line.isEmpty {
                flush()
                continue
            }
            if isHorizontalRule(line) {
                flush()
                continue
            }

            var text = line
            let isHeading = text.hasPrefix("#")
            let isBullet = stripBlockMarkers(&text)
            guard let spoken = speakableInline(text).nilIfBlank else { continue }
            if isHeading || isBullet {
                // Headings and bullets are usually fragments — close them so they pace as sentences.
                flush()
                paragraphs.append(ensureTerminalPunctuation(spoken))
            } else {
                current.append(spoken)
            }
        }

        if let count = fenceLineCount, count > 0 {
            // Unterminated fence (streaming transcript): still announce it.
            flush()
            paragraphs.append("\(count) line code block omitted.")
        }
        flush()
        return paragraphs
    }

    /// Strips heading / list / quote markers. Returns true when the line was a list item.
    private static func stripBlockMarkers(_ text: inout String) -> Bool {
        while text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("#") {
            text = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return false
        }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return true
        }
        if let match = text.firstMatch(of: /^\d{1,3}[.)]\s+/) {
            text = String(text[match.range.upperBound...])
            return true
        }
        return false
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }

    // MARK: - Inline pass

    private static func speakableInline(_ text: String) -> String {
        var result = text

        // Images vanish; links keep their label.
        result = result.replacing(/!\[[^\]]*\]\([^\)]*\)/, with: "")
        result = result.replacing(
            /\[([^\]]+)\]\([^\)]*\)/,
            with: { (match: Regex<(Substring, Substring)>.Match) in String(match.output.1) }
        )

        // Inline code: short identifiers read fine ("swift build"); long or multiline spans do not.
        result = result.replacing(
            /`([^`]*)`/,
            with: { (match: Regex<(Substring, Substring)>.Match) in
                let code = String(match.output.1)
                return code.count <= 30 ? code : "code"
            }
        )

        // Bare URLs → their host.
        result = result.replacing(
            /https?:\/\/([^\/\s\)>,]+)[^\s\)>,]*/,
            with: { (match: Regex<(Substring, Substring)>.Match) in String(match.output.1) }
        )

        // File paths → their basename ("Sources/App/Board.swift" reads as "Board.swift").
        result = result.replacing(
            /(?:~\/|\/)?(?:[\w@.+-]+\/){2,}[\w@.+-]+/,
            with: { (match: Regex<Substring>.Match) in
                (String(match.output) as NSString).lastPathComponent
            }
        )

        // Emphasis markers. Lone underscores stay (snake_case identifiers must survive).
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacing(
            /\b_([^_\s][^_]*)_\b/,
            with: { (match: Regex<(Substring, Substring)>.Match) in String(match.output.1) }
        )

        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sentences

    private static func splitIntoSentences(_ paragraph: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(paragraph)
        for (index, character) in characters.enumerated() {
            current.append(character)
            // Split only at punctuation followed by whitespace, so "Board.swift" and "1.5" survive.
            if ".!?".contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if next.isWhitespace {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty == false {
                        sentences.append(trimmed)
                    }
                    current = ""
                }
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespaces)
        if remainder.isEmpty == false {
            sentences.append(remainder)
        }
        return sentences
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?:".contains(last) ? text : text + "."
    }
}
