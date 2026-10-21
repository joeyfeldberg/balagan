import SwiftUI
import BalaganCore

/// The board's lane editing mode (Edit Lanes → Done): every column header becomes editable in place,
/// and a dashed column at the end adds a lane. Lanes live on `Project`; the edits go through
/// `BoardLanes.swift` and autosave like any other change.

/// A column header while editing: color, name, move left/right, hide, delete.
struct EditableLaneHeader: View {
    let lane: Lane
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let canDelete: Bool
    let onRename: (String) -> Void
    let onRecolor: (String) -> Void
    let onMove: (Int) -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void
    @Environment(\.balaganUIScale) private var scale
    @State private var draft = ""
    @State private var showingColors = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6 * scale) {
            Button { showingColors = true } label: {
                Circle()
                    .fill(lane.color)
                    .frame(width: 11 * scale, height: 11 * scale)
                    .overlay(Circle().stroke(Theme.hairlineStrong, lineWidth: 1))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .help("Lane color")
            .popover(isPresented: $showingColors, arrowEdge: .bottom) {
                LaneColorPicker(selected: lane.colorHex) { hex in
                    onRecolor(hex)
                    showingColors = false
                }
            }

            TextField("Lane name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                .foregroundStyle(lane.collapsed ? Theme.textTertiary : Theme.textPrimary)
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 3 * scale)
                .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Theme.bgWindow))
                .overlay(
                    RoundedRectangle(cornerRadius: 5 * scale)
                        .stroke(nameFocused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1)
                )
                .focused($nameFocused)
                .onSubmit(commit)
                .onChange(of: nameFocused) { _, focused in if focused == false { commit() } }
                .accessibilityIdentifier("lane-name-\(lane.status.accessibilitySlug)")

            iconButton("chevron.left", help: "Move left", disabled: isFirst) { onMove(-1) }
            iconButton("chevron.right", help: "Move right", disabled: isLast) { onMove(1) }
            iconButton(lane.collapsed ? "eye.slash" : "eye",
                       help: lane.collapsed ? "Hidden on the board (a thin strip); click to show" : "Hide on the board",
                       disabled: false, action: onToggleHidden)
            iconButton("trash",
                       help: canDelete ? "Delete lane" : (count > 0 ? "Move its \(count) task\(count == 1 ? "" : "s") out first" : "A board needs at least one lane"),
                       disabled: canDelete == false, role: .destructive, action: onDelete)
                .accessibilityIdentifier("lane-delete-\(lane.status.accessibilitySlug)")
        }
        .onAppear { draft = lane.name }
        .onChange(of: lane.name) { _, name in if nameFocused == false { draft = name } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { draft = lane.name } else if trimmed != lane.name { onRename(trimmed) }
    }

    private func iconButton(
        _ systemName: String, help: String, disabled: Bool, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .frame(width: 18 * scale, height: 18 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color(red: 0.88, green: 0.36, blue: 0.36) : Theme.textSecondary)
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(help)
    }
}

/// The palette as swatches, for a lane's color.
private struct LaneColorPicker: View {
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 5), spacing: 8) {
            ForEach(Lane.palette, id: \.self) { hex in
                Button { onPick(hex) } label: {
                    Circle()
                        .fill(Color(hexString: hex))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Theme.textPrimary, lineWidth: hex.caseInsensitiveCompare(selected) == .orderedSame ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }
}

/// The dashed column at the end of the board while editing: type a name, ⏎ adds the lane.
struct AddLaneColumn: View {
    let onAdd: (String) -> Void
    @Environment(\.balaganUIScale) private var scale
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: "plus")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("New lane", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                    .focused($focused)
                    .onSubmit(add)
                    .accessibilityIdentifier("new-lane-field")
            }
            .frame(height: 28 * scale)
            Text("Type a name and press Return")
                .font(.system(size: Theme.TextSize.small * scale))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(10 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        onAdd(trimmed)
        name = ""
        focused = true
    }
}
