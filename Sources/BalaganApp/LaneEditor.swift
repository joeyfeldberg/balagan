import AppKit
import SwiftUI
import BalaganCore

/// Everything about a lane is done on the lane itself, as on Trello, Linear and GitHub Projects: drag
/// its header to move it, double-click its name to rename it, and its ⋯ menu (also on right-click) for
/// the rest. Lanes live on `Project`; the mutations are in `BoardLanes.swift`.

/// What a lane header can do. On All Projects (lanes from several projects) only adding a task is offered.
struct LaneActions {
    var canEdit = false
    /// Why the lane can't be deleted, or nil when it can.
    var deleteBlocker: String? = "Unavailable"
    var isFirst = false
    var isLast = false
    var onRename: (String) -> Void = { _ in }
    var onRecolor: (String) -> Void = { _ in }
    var onMove: (Int) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onDelete: () -> Void = {}
    var onAddTask: () -> Void = {}
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }
}

struct LaneHeader: View {
    let lane: Lane
    let count: Int
    let actions: LaneActions
    /// The board's coordinate space, so drag translations line up with the lane frames.
    let boardSpace: String
    @Environment(\.balaganUIScale) private var scale
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 7 * scale) {
            Circle()
                .fill(lane.color)
                .frame(width: 7 * scale, height: 7 * scale)
            if renaming {
                TextField("Lane name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(RoundedRectangle(cornerRadius: 5 * scale).fill(Theme.bgWindow))
                    .overlay(RoundedRectangle(cornerRadius: 5 * scale).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, focused in if focused == false { commitRename() } }
                    .accessibilityIdentifier("column-rename-field")
            } else {
                Text(lane.name)
                    .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { if actions.canEdit { beginRename() } }
                    .accessibilityIdentifier("column-\(lane.status.accessibilitySlug)")
            }
            Text("\(count)")
                .font(.system(size: Theme.TextSize.small * scale, weight: .medium, design: .rounded))
                .foregroundStyle(lane.color)
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 1 * scale)
                .background(lane.color.opacity(0.16), in: Capsule())
            Spacer(minLength: 0)
            // + and ⋯ appear on hover, so a quiet board stays quiet.
            Group {
                Button(action: actions.onAddTask) {
                    Image(systemName: "plus")
                        .frame(width: 22 * scale, height: 22 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New task in \(lane.name)")
                .accessibilityIdentifier("lane-add-task-\(lane.status.accessibilitySlug)")
                Menu {
                    LaneMenuItems(lane: lane, actions: actions, onRename: beginRename)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22 * scale, height: 22 * scale)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Lane actions")
                .accessibilityIdentifier("lane-menu-\(lane.status.accessibilitySlug)")
            }
            .font(.system(size: 11.5 * scale, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .opacity(hovering || renaming ? 1 : 0)
        }
        .frame(height: 28 * scale)
        .padding(.horizontal, 2 * scale)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { LaneMenuItems(lane: lane, actions: actions, onRename: beginRename) }
        // Drag the header to move the lane (only where lanes can be edited).
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(boardSpace))
                .onChanged { if actions.canEdit, renaming == false { actions.onDragChanged($0.translation.width) } }
                .onEnded { if actions.canEdit, renaming == false { actions.onDragEnded($0.translation.width) } },
            including: actions.canEdit ? .all : .subviews
        )
        .help(actions.canEdit ? "Drag to move · double-click to rename" : "")
    }

    private func beginRename() {
        draft = lane.name
        renaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false, trimmed != lane.name { actions.onRename(trimmed) }
    }
}

/// The lane's ⋯ menu, also its right-click menu.
private struct LaneMenuItems: View {
    let lane: Lane
    let actions: LaneActions
    let onRename: () -> Void

    var body: some View {
        Button { actions.onAddTask() } label: { Label("New Task Here", systemImage: "plus") }
        if actions.canEdit {
            Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
            Menu {
                ForEach(Lane.palette, id: \.self) { hex in
                    Button { actions.onRecolor(hex) } label: {
                        Label { Text(Lane.colorName(hex)) } icon: { Image(nsImage: LaneColorDot.image(hex: hex)) }
                    }
                }
            } label: { Label("Color", systemImage: "paintpalette") }
            Divider()
            Button { actions.onMove(-1) } label: { Label("Move Left", systemImage: "arrow.left") }
                .disabled(actions.isFirst)
            Button { actions.onMove(1) } label: { Label("Move Right", systemImage: "arrow.right") }
                .disabled(actions.isLast)
            Button { actions.onHide() } label: { Label("Hide Lane", systemImage: "eye.slash") }
            Divider()
            Button(role: .destructive) { actions.onDelete() } label: {
                Label(actions.deleteBlocker.map { "Delete Lane (\($0))" } ?? "Delete Lane", systemImage: "trash")
            }
            .disabled(actions.deleteBlocker != nil)
            .accessibilityIdentifier("lane-delete-\(lane.status.accessibilitySlug)")
        }
    }
}

/// A colored dot as a non-template image, so menus show the lane color instead of tinting it.
enum LaneColorDot {
    static func image(hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color(hexString: hex)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension Lane {
    /// A name for each palette color, for the Color menu.
    static func colorName(_ hex: String) -> String {
        switch hex.uppercased() {
        case "8A93A6": return "Slate"
        case "4C8DFF": return "Blue"
        case "3FB970": return "Green"
        case "C98A2B": return "Amber"
        case "B980FF": return "Purple"
        case "FF6B6B": return "Red"
        case "3FC7C7": return "Teal"
        case "E0A23C": return "Gold"
        case "7E8CA0": return "Gray"
        default: return "#\(hex)"
        }
    }
}

/// The slim dashed + after the last lane; it opens into a name field, and Return adds the lane.
struct AddLaneButton: View {
    let onAdd: (String) -> Void
    @Environment(\.balaganUIScale) private var scale
    @State private var open = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if open {
                VStack(alignment: .leading, spacing: 6 * scale) {
                    TextField("Lane name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                        .padding(.horizontal, 7 * scale)
                        .padding(.vertical, 5 * scale)
                        .background(RoundedRectangle(cornerRadius: 6 * scale).fill(Theme.bgWindow))
                        .overlay(RoundedRectangle(cornerRadius: 6 * scale).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                        .focused($focused)
                        .onSubmit(add)
                        .onExitCommand(perform: close)
                        .onChange(of: focused) { _, isFocused in if isFocused == false, name.isEmpty { close() } }
                        .accessibilityIdentifier("new-lane-field")
                    Text("Return adds the lane · Esc cancels")
                        .font(.system(size: Theme.TextSize.micro * scale))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(10 * scale)
                .frame(width: KanbanBoard.laneWidth * scale, alignment: .topLeading)
            } else {
                Button {
                    open = true
                    focused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14 * scale, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40 * scale)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a lane")
                .accessibilityIdentifier("add-lane-button")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return close() }
        onAdd(trimmed)
        name = ""
        focused = true
    }

    private func close() {
        open = false
        name = ""
    }
}

/// The one-line "+ Add task" at the bottom of a lane: Return creates a task with that title in this lane.
struct QuickAddTask: View {
    @Binding var isOpen: Bool
    let onAdd: (String) -> Void
    @Environment(\.balaganUIScale) private var scale
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isOpen {
            VStack(alignment: .leading, spacing: 5 * scale) {
                TextField("Task title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.TextSize.title * scale, weight: .semibold))
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 8 * scale)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand(perform: close)
                    .onChange(of: focused) { _, isFocused in if isFocused == false, title.isEmpty { close() } }
                    .onAppear { focused = true }
                    .accessibilityIdentifier("quick-add-task-field")
                Text("Return adds it · Esc cancels · ⌘N for the full form")
                    .font(.system(size: Theme.TextSize.micro * scale))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            Button { isOpen = true } label: {
                Label("Add task", systemImage: "plus")
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4 * scale)
                    .padding(.vertical, 5 * scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quick-add-task-button")
        }
    }

    private func add() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return close() }
        onAdd(trimmed)
        title = ""
        focused = true
    }

    private func close() {
        isOpen = false
        title = ""
    }
}
