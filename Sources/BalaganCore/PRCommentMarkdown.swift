import Foundation

/// A coarse markdown block, enough to render a GitHub PR comment readably in a compact panel without
/// a full markdown engine. Pure/Foundation-only and unit-tested; the SwiftUI layer switches over these.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case quote(String)
    case code(String)
    /// A GitHub table, collapsed to a row count (they never render well in a narrow column, and the
    /// full PR is one click away). `rows` counts data rows (excludes the header + separator).
    case table(rows: Int)
    case rule
}

public enum PRCommentMarkdown {
    /// Parses a raw comment body into coarse blocks. Emoji shortcodes are mapped, HTML comments and
    /// tags stripped, and GitHub tables collapsed to a `.table` chip.
    public static func blocks(from body: String) -> [MarkdownBlock] {
        let cleaned = stripHTML(replacingShortcodes(in: body))
        let lines = cleaned.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]? = nil   // non-nil while inside a fenced code block

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if joined.isEmpty == false { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks.
            if trimmed.hasPrefix("```") {
                if var accumulating = codeLines {
                    blocks.append(.code(accumulating.joined(separator: "\n")))
                    accumulating.removeAll()
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                index += 1
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                index += 1
                continue
            }

            // Blank line = paragraph break.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Table: a `|` row immediately followed by a `|---|` separator row → collapse the run.
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var dataRows = 0
                var cursor = index + 2
                while cursor < lines.count, lines[cursor].contains("|"),
                      lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty == false {
                    dataRows += 1
                    cursor += 1
                }
                blocks.append(.table(rows: dataRows))
                index = cursor
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Heading.
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // Bullet / numbered list item.
            if let bullet = parseBullet(line) {
                flushParagraph()
                blocks.append(bullet)
                index += 1
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == ">" || $0 == " " }))
                blocks.append(.quote(text))
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        if let leftover = codeLines, leftover.isEmpty == false {
            blocks.append(.code(leftover.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// A one-line, markdown-stripped synopsis for a collapsed (bot) comment: the first heading, else
    /// the first non-empty paragraph.
    public static func synopsis(from body: String) -> String {
        for block in blocks(from: body) {
            switch block {
            case .heading(_, let text): return text
            case .paragraph(let text): return text
            case .bullet(_, let text): return text
            case .quote(let text): return text
            default: continue
            }
        }
        return "(no text)"
    }

    // MARK: - Line helpers

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseBullet(_ line: String) -> MarkdownBlock? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let depth = leadingSpaces / 2
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return .bullet(depth: depth, text: String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
        // Numbered: "1. text"
        if let dotIndex = trimmed.firstIndex(of: "."),
           trimmed[trimmed.startIndex..<dotIndex].allSatisfy(\.isNumber),
           trimmed.startIndex != dotIndex,
           trimmed.index(after: dotIndex) < trimmed.endIndex,
           trimmed[trimmed.index(after: dotIndex)] == " " {
            let text = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
            return .bullet(depth: depth, text: text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A markdown table separator like `|---|:--:|` (only `|`, `-`, `:`, spaces, and at least one `-`).
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func stripHTML(_ text: String) -> String {
        var result = text
        // Drop HTML comments (bots hide markers/metadata in them).
        result = result.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        // Turn <summary>…</summary> into a heading-ish line so <details> keep a label.
        result = result.replacingOccurrences(
            of: "<summary>([\\s\\S]*?)</summary>", with: "### $1", options: .regularExpression)
        // Strip remaining tags.
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return result
    }

    private static func replacingShortcodes(in text: String) -> String {
        guard text.contains(":") else { return text }
        var result = text
        for (code, emoji) in emojiShortcodes {
            result = result.replacingOccurrences(of: code, with: emoji)
        }
        return result
    }

    /// The shortcodes that actually show up in PR/bot comments. Unknown ones are left as-is.
    static let emojiShortcodes: [String: String] = [
        ":white_check_mark:": "✅", ":heavy_check_mark:": "✔️", ":x:": "❌", ":warning:": "⚠️",
        ":rocket:": "🚀", ":tada:": "🎉", ":bar_chart:": "📊", ":chart_with_upwards_trend:": "📈",
        ":memo:": "📝", ":pencil:": "✏️", ":bug:": "🐛", ":sparkles:": "✨", ":fire:": "🔥",
        ":bulb:": "💡", ":eyes:": "👀", ":wrench:": "🔧", ":zap:": "⚡️", ":package:": "📦",
        ":recycle:": "♻️", ":green_circle:": "🟢", ":red_circle:": "🔴", ":yellow_circle:": "🟡",
        ":information_source:": "ℹ️", ":point_right:": "👉", ":arrow_up:": "⬆️", ":lock:": "🔒",
        ":hammer:": "🔨", ":art:": "🎨", ":books:": "📚", ":robot:": "🤖", ":clipboard:": "📋",
    ]
}
