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
        ReaderItem.grouping(tailer.entries)
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
                        NSPasteboard.copy(entry.text)
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
        if toolCount > 0 { parts.append(toolCount.counted("tool call")) }
        if thoughtCount > 0 { parts.append(thoughtCount.counted("thought")) }
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
