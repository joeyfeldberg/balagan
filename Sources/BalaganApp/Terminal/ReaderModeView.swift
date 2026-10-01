import AppKit
import SwiftUI
import BalaganCore

/// Reader mode: a typographic rendering of the active surface's agent conversation, shown in place
/// of the terminal pane (the terminal keeps running untouched — its host stays cached in
/// `TerminalHostRegistry`, exactly like an unselected tab). Prose renders as markdown in a
/// reading-width column; user prompts are compact role-distinct cards; tool calls collapse into
/// activity rows. Content live-follows the transcript while open.
struct ReaderModeView: View {
    let source: ReaderTranscriptSource?
    /// Scrollback text for surfaces without an agent transcript (plain shells).
    let fallbackText: String?
    let fontSize: Double
    let theme: ReaderTheme
    let onAdjustFontSize: (Double) -> Void
    let onSelectTheme: (ReaderTheme) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let palette = ReaderPalette.palette(for: theme)
        Group {
            if let source {
                TranscriptReaderContent(
                    source: source,
                    fontSize: fontSize,
                    theme: theme,
                    palette: palette,
                    onAdjustFontSize: onAdjustFontSize,
                    onSelectTheme: onSelectTheme,
                    onDismiss: onDismiss
                )
                .id(source.path)
            } else {
                PlainReaderContent(
                    text: fallbackText ?? "",
                    fontSize: fontSize,
                    theme: theme,
                    palette: palette,
                    onAdjustFontSize: onAdjustFontSize,
                    onSelectTheme: onSelectTheme,
                    onDismiss: onDismiss
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .accessibilityIdentifier("reader-mode")
    }
}

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

// MARK: - Display grouping

/// What the reader actually lays out: assistant prose is the star, user prompts stay visible, and
/// runs of tool calls / thinking collapse into one expandable activity row.
private enum ReaderItem: Identifiable {
    case prose(TranscriptEntry)
    case user(TranscriptEntry)
    case activity([TranscriptEntry])

    var id: String {
        switch self {
        case let .prose(entry): return "prose-\(entry.id)"
        case let .user(entry): return "user-\(entry.id)"
        case let .activity(entries): return "activity-\(entries.first?.id ?? "?")"
        }
    }

    var isProse: Bool {
        if case .prose = self { return true }
        return false
    }
}

private func readerItems(from entries: [TranscriptEntry]) -> [ReaderItem] {
    var items: [ReaderItem] = []
    var activityRun: [TranscriptEntry] = []
    func flushActivity() {
        if activityRun.isEmpty == false {
            items.append(.activity(activityRun))
            activityRun = []
        }
    }
    for entry in entries {
        switch entry.kind {
        case .assistant:
            flushActivity()
            items.append(.prose(entry))
        case .user:
            flushActivity()
            items.append(.user(entry))
        case .toolUse, .thinking:
            activityRun.append(entry)
        }
    }
    flushActivity()
    return items
}

// MARK: - Transcript-backed reader

private struct TranscriptReaderContent: View {
    let source: ReaderTranscriptSource
    let fontSize: Double
    let theme: ReaderTheme
    let palette: ReaderPalette
    let onAdjustFontSize: (Double) -> Void
    let onSelectTheme: (ReaderTheme) -> Void
    let onDismiss: () -> Void

    @StateObject private var tailer: TranscriptTailer
    @State private var expandedActivityIDs: Set<String> = []
    @State private var followsTail = true
    /// How many trailing items render. Eager layout (plain VStack) is what makes the bottom scroll
    /// anchor exact — a LazyVStack opens blank because the items near the bottom aren't laid out
    /// yet — so long histories are capped and revealed in chunks instead of lazily.
    @State private var visibleItemLimit = TranscriptReaderContent.itemChunk
    private static let itemChunk = 120
    @FocusState private var isFocused: Bool

    init(
        source: ReaderTranscriptSource,
        fontSize: Double,
        theme: ReaderTheme,
        palette: ReaderPalette,
        onAdjustFontSize: @escaping (Double) -> Void,
        onSelectTheme: @escaping (ReaderTheme) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.source = source
        self.fontSize = fontSize
        self.theme = theme
        self.palette = palette
        self.onAdjustFontSize = onAdjustFontSize
        self.onSelectTheme = onSelectTheme
        self.onDismiss = onDismiss
        _tailer = StateObject(wrappedValue: TranscriptTailer(source: source))
    }

    private var items: [ReaderItem] {
        readerItems(from: tailer.entries)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            ReaderTopBar(
                title: taskBarTitle,
                fontSize: fontSize,
                theme: theme,
                palette: palette,
                followsTail: $followsTail,
                onAdjustFontSize: onAdjustFontSize,
                onSelectTheme: onSelectTheme,
                onDismiss: onDismiss
            )

            if tailer.fileExists == false {
                ReaderEmptyState(
                    symbol: "doc.questionmark",
                    message: "Transcript not found on disk.",
                    detail: source.path,
                    palette: palette
                )
            } else if items.isEmpty {
                ReaderEmptyState(
                    symbol: "text.bubble",
                    message: "No conversation yet.",
                    detail: "Entries appear here as the agent works.",
                    palette: palette
                )
            } else {
                let visibleItems = Array(items.suffix(visibleItemLimit))
                let hiddenCount = items.count - visibleItems.count
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: fontSize * 0.9) {
                            if hiddenCount > 0 {
                                showEarlierButton(hiddenCount: hiddenCount, firstVisibleID: visibleItems.first?.id, proxy: proxy)
                            }
                            ForEach(visibleItems) { item in
                                itemView(item)
                                    .id(item.id)
                            }
                        }
                        .frame(maxWidth: fontSize * 34, alignment: .leading)   // ~68ch measure
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        // Generous end padding so the newest line doesn't hug the pane edge while
                        // live-following (and the last response has room to breathe).
                        .padding(.bottom, 96)
                        .frame(maxWidth: .infinity)
                    }
                    // Open at the newest content and stay pinned there until the user scrolls away.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: visibleItems.last?.id) { _, newValue in
                        guard followsTail, let newValue else { return }
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .bottom)
                        }
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        guard press.modifiers.contains(.option) else { return .ignored }
                        jumpToProse(direction: press.key == .upArrow ? -1 : 1, items: visibleItems, proxy: proxy)
                        return .handled
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onExitCommand(perform: onDismiss)
        .onAppear {
            isFocused = true
            tailer.start()
        }
        .onDisappear {
            tailer.stop()
        }
    }

    private var taskBarTitle: String {
        source.format == .claude ? "Claude session" : "Codex session"
    }

    /// Reveals the next chunk of older history, keeping the viewport where it was (anchored to the
    /// previously-first item) instead of snapping back to the bottom.
    private func showEarlierButton(hiddenCount: Int, firstVisibleID: String?, proxy: ScrollViewProxy) -> some View {
        Button {
            visibleItemLimit += Self.itemChunk
            if let firstVisibleID {
                DispatchQueue.main.async {
                    proxy.scrollTo(firstVisibleID, anchor: .top)
                }
            }
        } label: {
            Label("Show earlier conversation (\(hiddenCount) more)", systemImage: "arrow.up.circle")
                .font(.system(size: fontSize * 0.82))
                .foregroundStyle(palette.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(.bottom, fontSize * 0.5)
        .accessibilityIdentifier("reader-show-earlier-button")
    }

    /// ⌥↑ / ⌥↓ — jump between assistant responses.
    @State private var proseCursor: Int?
    private func jumpToProse(direction: Int, items: [ReaderItem], proxy: ScrollViewProxy) {
        let proseIndices = items.indices.filter { items[$0].isProse }
        guard proseIndices.isEmpty == false else { return }
        followsTail = false
        let current = proseCursor ?? proseIndices.last ?? 0
        let position = proseIndices.firstIndex { $0 >= current } ?? proseIndices.count - 1
        let next = min(max(position + direction, 0), proseIndices.count - 1)
        proseCursor = proseIndices[next]
        withAnimation(.linear(duration: 0.1)) {
            proxy.scrollTo(items[proseIndices[next]].id, anchor: .top)
        }
    }

    @ViewBuilder
    private func itemView(_ item: ReaderItem) -> some View {
        switch item {
        case let .prose(entry):
            ReaderMarkdownView(markdown: entry.text, fontSize: fontSize, palette: palette)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Speak This Response") {
                        SpeechController.shared.speak(markdown: entry.text)
                    }
                    Button("Copy Response") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                }
        case let .user(entry):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: Theme.radiusSelectionBar)
                    .fill(palette.accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You")
                        .font(.system(size: fontSize * 0.72, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                        .textCase(.uppercase)
                    Text(entry.text)
                        .font(.system(size: fontSize * 0.92))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        case let .activity(entries):
            ReaderActivityRow(
                entries: entries,
                fontSize: fontSize,
                palette: palette,
                isExpanded: expandedActivityIDs.contains(item.id),
                onToggle: {
                    if expandedActivityIDs.contains(item.id) {
                        expandedActivityIDs.remove(item.id)
                    } else {
                        expandedActivityIDs.insert(item.id)
                    }
                }
            )
        }
    }
}

// MARK: - Plain reader (no transcript: re-wrapped scrollback)

private struct PlainReaderContent: View {
    let text: String
    let fontSize: Double
    let theme: ReaderTheme
    let palette: ReaderPalette
    let onAdjustFontSize: (Double) -> Void
    let onSelectTheme: (ReaderTheme) -> Void
    let onDismiss: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ReaderTopBar(
                title: "Terminal scrollback",
                fontSize: fontSize,
                theme: theme,
                palette: palette,
                followsTail: nil,
                onAdjustFontSize: onAdjustFontSize,
                onSelectTheme: onSelectTheme,
                onDismiss: onDismiss
            )
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReaderEmptyState(
                    symbol: "text.page",
                    message: "Nothing to read yet.",
                    detail: "This tab has no agent session and no captured scrollback.",
                    palette: palette
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: fontSize * 0.92, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .lineSpacing(fontSize * 0.38)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: fontSize * 46, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 96)
                        .frame(maxWidth: .infinity)
                }
                // Scrollback's most recent output is at the end — open there.
                .defaultScrollAnchor(.bottom)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onExitCommand(perform: onDismiss)
        .onAppear { isFocused = true }
    }
}

// MARK: - Chrome

private struct ReaderTopBar: View {
    let title: String
    let fontSize: Double
    let theme: ReaderTheme
    let palette: ReaderPalette
    /// nil hides the follow toggle (plain reader has no live tail).
    var followsTail: Binding<Bool>?
    let onAdjustFontSize: (Double) -> Void
    let onSelectTheme: (ReaderTheme) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: "text.book.closed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            Spacer()

            if let followsTail {
                Toggle(isOn: followsTail) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(followsTail.wrappedValue ? palette.accent : palette.textTertiary)
                .help("Follow new entries")
                .accessibilityIdentifier("reader-follow-toggle")

                Divider().frame(height: 14)
            }

            // The Safari Reader trio, as swatches showing each theme's paper color.
            HStack(spacing: 6) {
                ForEach(ReaderTheme.allCases) { option in
                    themeSwatch(option)
                }
            }

            Divider().frame(height: 14)

            Button {
                onAdjustFontSize(-UIAppearanceSettings.readerFontSizeStep)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.textSecondary)
            .help("Smaller text")
            .accessibilityIdentifier("reader-font-decrease")

            Button {
                onAdjustFontSize(UIAppearanceSettings.readerFontSizeStep)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.textSecondary)
            .help("Larger text")
            .accessibilityIdentifier("reader-font-increase")
            // No close button: the header's Terminal | Reader | Changes switch (and Esc) goes back.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }

    private func themeSwatch(_ option: ReaderTheme) -> some View {
        let optionPalette = ReaderPalette.palette(for: option)
        let isSelected = option == theme
        return Button {
            onSelectTheme(option)
        } label: {
            Circle()
                .fill(optionPalette.background)
                .overlay(Circle().strokeBorder(optionPalette.textTertiary.opacity(0.7), lineWidth: 1))
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(palette.accent, lineWidth: 1.5).padding(-2.5)
                    }
                }
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .help("\(option.displayName) theme")
        .accessibilityIdentifier("reader-theme-\(option.rawValue)")
    }
}

private struct ReaderEmptyState: View {
    let symbol: String
    let message: String
    let detail: String
    let palette: ReaderPalette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(palette.textTertiary)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// One collapsed row for a run of tool calls / thinking between prose. Expanding lists each step.
private struct ReaderActivityRow: View {
    let entries: [TranscriptEntry]
    let fontSize: Double
    let palette: ReaderPalette
    let isExpanded: Bool
    let onToggle: () -> Void

    private var summary: String {
        var toolCount = 0
        var thoughtCount = 0
        for entry in entries {
            if case .toolUse = entry.kind {
                toolCount += 1
            } else {
                thoughtCount += 1
            }
        }
        var parts: [String] = []
        if toolCount > 0 { parts.append("\(toolCount) tool call\(toolCount == 1 ? "" : "s")") }
        if thoughtCount > 0 { parts.append("\(thoughtCount) thought\(thoughtCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: fontSize * 0.55, weight: .semibold))
                    Image(systemName: "gearshape")
                        .font(.system(size: fontSize * 0.7))
                    Text(summary)
                        .font(.system(size: fontSize * 0.78))
                }
                .foregroundStyle(palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader-activity-row")

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            switch entry.kind {
                            case let .toolUse(name):
                                Text(name)
                                    .font(.system(size: fontSize * 0.75, weight: .medium, design: .monospaced))
                                    .foregroundStyle(palette.textSecondary)
                                Text(entry.text)
                                    .font(.system(size: fontSize * 0.75, design: .monospaced))
                                    .foregroundStyle(palette.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            default:
                                Text("Thinking")
                                    .font(.system(size: fontSize * 0.75, weight: .medium))
                                    .foregroundStyle(palette.textTertiary)
                                Text(entry.text)
                                    .font(.system(size: fontSize * 0.75))
                                    .foregroundStyle(palette.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
                .padding(.leading, fontSize * 1.2)
            }
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
            Label("Table (\(rows) row\(rows == 1 ? "" : "s"))", systemImage: "tablecells")
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
