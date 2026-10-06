import SwiftUI

/// A single entry in the ⌘⇧P command palette: an action or a place to jump to.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var systemImage: String = "command"
    /// The command's keyboard shortcut ("⇧⌘G"), shown on the right so the palette teaches them.
    var shortcut: String? = nil
    let run: () -> Void
}

/// VS Code-style command palette: a fuzzy-filterable list of actions + navigation, driven from the
/// keyboard (type to filter, ↑/↓ to move, ⏎ to run, Esc to close). Opened with ⌘⇧P.
struct CommandPalette: View {
    let commands: [PaletteCommand]
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.balaganUIScale) private var scale

    private var results: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else { return commands }
        return commands.filter { command in
            (command.title + " " + (command.subtitle ?? "")).lowercased().contains(trimmed)
        }
    }

    private var clampedSelection: Int {
        guard results.isEmpty == false else { return 0 }
        return min(max(selection, 0), results.count - 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 8 * scale) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Search commands, tasks, agents…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15 * scale))
                        .focused($searchFocused)
                        .onSubmit { runSelected() }
                }
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 11 * scale)

                Divider()

                if results.isEmpty {
                    Text("No matching commands")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14 * scale)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                // Rows are identified by command, never by position: an index id made the lazy
                                // list keep a stale row (typing "sleep" showed the previous first row,
                                // Reader Mode, while ⏎ would run Sleep Task).
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                    row(command, isSelected: index == clampedSelection)
                                        .contentShape(Rectangle())
                                        .onTapGesture { run(command) }
                                }
                            }
                        }
                        .frame(maxHeight: 340 * scale)
                        .onChange(of: clampedSelection) { _, newValue in
                            guard results.indices.contains(newValue) else { return }
                            withAnimation(.linear(duration: 0.06)) { proxy.scrollTo(results[newValue].id) }
                        }
                    }
                }
            }
            .frame(width: 560 * scale)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12 * scale))
            .overlay(RoundedRectangle(cornerRadius: 12 * scale).stroke(Theme.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.top, 90 * scale)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onExitCommand { onDismiss() }
    }

    private func move(_ delta: Int) {
        guard results.isEmpty == false else { return }
        selection = (clampedSelection + delta + results.count) % results.count
    }

    private func runSelected() {
        guard results.indices.contains(clampedSelection) else { return }
        run(results[clampedSelection])
    }

    private func run(_ command: PaletteCommand) {
        onDismiss()
        // Run next tick so dismissing the overlay doesn't collide with a command that presents a sheet.
        DispatchQueue.main.async { command.run() }
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: command.systemImage)
                .frame(width: 18 * scale)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13.5 * scale))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 7 * scale)
        .background(isSelected ? Theme.accentSoft : Color.clear)
    }
}
