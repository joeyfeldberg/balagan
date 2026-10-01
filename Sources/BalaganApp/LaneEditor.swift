import AppKit
import SwiftUI
import BalaganCore

/// Popover to manage a board's lanes (kanban columns): rename, reorder, delete (only when empty), and
/// add. Reads/writes `BoardViewModel` directly so edits are live.
struct LaneEditorView: View {
    @ObservedObject var viewModel: BoardViewModel
    let projectID: Project.ID
    @State private var newLaneName = ""
    @FocusState private var addFieldFocused: Bool

    private var lanes: [Lane] {
        viewModel.projects.first { $0.id == projectID }?.lanes ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lanes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 6) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    LaneEditorRow(
                        lane: lane,
                        count: viewModel.laneTaskCount(projectID: projectID, laneID: lane.id),
                        isFirst: index == 0,
                        isLast: index == lanes.count - 1,
                        canDelete: viewModel.canDeleteLane(projectID: projectID, laneID: lane.id),
                        onRename: { viewModel.renameLane(projectID: projectID, laneID: lane.id, to: $0) },
                        onMoveUp: { viewModel.moveLane(projectID: projectID, laneID: lane.id, by: -1) },
                        onMoveDown: { viewModel.moveLane(projectID: projectID, laneID: lane.id, by: 1) },
                        onToggleCollapse: { viewModel.toggleLaneCollapsed(projectID: projectID, laneID: lane.id) },
                        onDelete: { viewModel.deleteLane(projectID: projectID, laneID: lane.id) }
                    )
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("New lane", text: $newLaneName)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFieldFocused)
                    .onSubmit(addLane)
                    .accessibilityIdentifier("lane-editor-add-field")
                Button("Add", action: addLane)
                    .disabled(newLaneName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("lane-editor-add-button")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func addLane() {
        let name = newLaneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        viewModel.addLane(toProjectID: projectID, name: name)
        newLaneName = ""
        addFieldFocused = true
    }
}

private struct LaneEditorRow: View {
    let lane: Lane
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let canDelete: Bool
    let onRename: (String) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleCollapse: () -> Void
    let onDelete: () -> Void

    @State private var draft: String
    @FocusState private var nameFocused: Bool

    init(
        lane: Lane,
        count: Int,
        isFirst: Bool,
        isLast: Bool,
        canDelete: Bool,
        onRename: @escaping (String) -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onToggleCollapse: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.lane = lane
        self.count = count
        self.isFirst = isFirst
        self.isLast = isLast
        self.canDelete = canDelete
        self.onRename = onRename
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onToggleCollapse = onToggleCollapse
        self.onDelete = onDelete
        _draft = State(initialValue: lane.name)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(lane.color).frame(width: 9, height: 9)

            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit(commit)
                .onChange(of: nameFocused) { _, focused in
                    if focused {
                        // Select the whole name on focus (a clean rename — type to replace) instead of
                        // AppKit's default word-selection at the click point.
                        DispatchQueue.main.async {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        }
                    } else {
                        commit()
                    }
                }
                .accessibilityIdentifier("lane-editor-name-\(lane.id)")

            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(minWidth: 16, alignment: .trailing)

            Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
            Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
            Button(action: onToggleCollapse) {
                Image(systemName: lane.collapsed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(lane.collapsed ? "Show lane" : "Hide lane (collapse to a thin strip)")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(canDelete == false)
                .help(canDelete
                    ? "Delete lane"
                    : (count > 0 ? "Move its tasks out first" : "A board keeps at least one lane"))
                .accessibilityIdentifier("lane-editor-delete-\(lane.id)")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = lane.name   // reject a blank name
        } else if trimmed != lane.name {
            onRename(trimmed)
        }
    }
}
