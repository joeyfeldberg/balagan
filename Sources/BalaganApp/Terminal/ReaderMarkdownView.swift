import SwiftUI
import BalaganCore

// MARK: - Palette

/// Reader colors per theme. The dark variant deliberately dims body text to a soft off-white on a
/// slightly lifted background — maximum-contrast white-on-black blooms (halation) on long reads.
struct ReaderPalette {
    var background: Color
    var bar: Color
    var card: Color
    var codeBackground: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    /// Inline `code` text. Deliberately at (or just below) body brightness — the SwiftUI markdown
    /// default renders inline code *brighter* than the surrounding prose, which inverts the reading
    /// hierarchy (identifiers/paths shout over the sentence). A calm, slightly-tinted color plus a
    /// smaller monospace size lets code read as code without dominating.
    var codeText: Color
    var accent: Color
    var hairline: Color

    static func palette(for theme: ReaderTheme) -> ReaderPalette {
        switch theme {
        case .dark:
            return ReaderPalette(
                background: Color(red: 26 / 255, green: 28 / 255, blue: 32 / 255),      // #1A1C20
                bar: Color(red: 32 / 255, green: 35 / 255, blue: 41 / 255),             // #202329
                card: Color(red: 34 / 255, green: 37 / 255, blue: 43 / 255),            // #22252B
                codeBackground: Color(red: 36 / 255, green: 39 / 255, blue: 46 / 255),  // #24272E
                textPrimary: Color(red: 201 / 255, green: 206 / 255, blue: 214 / 255),  // #C9CED6
                textSecondary: Color(red: 153 / 255, green: 161 / 255, blue: 172 / 255),
                textTertiary: Color(red: 108 / 255, green: 115 / 255, blue: 126 / 255),
                codeText: Color(red: 158 / 255, green: 187 / 255, blue: 209 / 255),     // #9EBBD1 soft blue
                accent: Theme.accent,
                hairline: Color.white.opacity(0.08)
            )
        case .sepia:
            return ReaderPalette(
                background: Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255),   // #F4ECD8
                bar: Color(red: 237 / 255, green: 227 / 255, blue: 204 / 255),
                card: Color(red: 238 / 255, green: 229 / 255, blue: 208 / 255),
                codeBackground: Color(red: 234 / 255, green: 224 / 255, blue: 197 / 255),
                textPrimary: Color(red: 67 / 255, green: 56 / 255, blue: 42 / 255),     // #43382A
                textSecondary: Color(red: 110 / 255, green: 95 / 255, blue: 75 / 255),
                textTertiary: Color(red: 153 / 255, green: 133 / 255, blue: 106 / 255),
                codeText: Color(red: 122 / 255, green: 78 / 255, blue: 54 / 255),       // warm brown
                accent: Color(red: 138 / 255, green: 109 / 255, blue: 59 / 255),        // warm brown
                hairline: Color.black.opacity(0.12)
            )
        case .light:
            return ReaderPalette(
                background: Color(red: 251 / 255, green: 251 / 255, blue: 249 / 255),   // #FBFBF9
                bar: Color(red: 242 / 255, green: 242 / 255, blue: 240 / 255),
                card: Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255),
                codeBackground: Color(red: 239 / 255, green: 241 / 255, blue: 244 / 255),
                textPrimary: Color(red: 36 / 255, green: 41 / 255, blue: 47 / 255),     // #24292F
                textSecondary: Color(red: 87 / 255, green: 96 / 255, blue: 106 / 255),
                textTertiary: Color(red: 140 / 255, green: 149 / 255, blue: 159 / 255),
                codeText: Color(red: 60 / 255, green: 80 / 255, blue: 120 / 255),       // slate blue
                accent: Theme.accent,
                hairline: Color.black.opacity(0.10)
            )
        }
    }
}

// MARK: - Scaled markdown

/// `MarkdownBlockView`'s reading-size sibling: same `PRCommentMarkdown` blocks, but proportional
/// type at the reader's font size with book-like spacing (the PR variant is locked to panel sizes).
struct ReaderMarkdownView: View {
    let markdown: String
    let fontSize: Double
    let palette: ReaderPalette

    var body: some View {
        let blocks = PRCommentMarkdown.blocks(from: markdown)
        VStack(alignment: .leading, spacing: fontSize * 0.78) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: fontSize * (level <= 2 ? 1.3 : 1.1), weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, fontSize * 0.4)
        case .paragraph(let text):
            inline(text)
                .font(.system(size: fontSize))
                .foregroundStyle(palette.textPrimary)
                .lineSpacing(fontSize * 0.46)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.45) {
                Text("•").foregroundStyle(palette.textTertiary)
                inline(text)
                    .lineSpacing(fontSize * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: fontSize))
            .foregroundStyle(palette.textPrimary)
            .padding(.leading, CGFloat(depth) * fontSize)
        case .quote(let text):
            HStack(spacing: fontSize * 0.5) {
                RoundedRectangle(cornerRadius: 1).fill(palette.hairline).frame(width: 2)
                inline(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(fontSize * 0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize * 0.85, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .padding(fontSize * 0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        case .table(let rows):
            Label("Table (\(rows.counted("row")))", systemImage: "tablecells")
                .font(.system(size: fontSize * 0.8))
                .foregroundStyle(palette.textTertiary)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text)
        }
        // Re-style inline `code`: the markdown default renders it brighter than the prose, which makes
        // identifiers/paths dominate the sentence. Calm the color and drop the size a touch so code
        // reads as code without shouting.
        let codeRanges = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in codeRanges {
            attributed[range].font = .system(size: fontSize * 0.9, design: .monospaced)
            attributed[range].foregroundColor = palette.codeText
        }
        return Text(attributed)
    }
}
