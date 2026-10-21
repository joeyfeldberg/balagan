import AppKit
import SwiftUI
import BalaganCore

/// Board-space frame of each kanban column, used to resolve a drag's drop target by hit-testing.
private struct ColumnFrameKey: PreferenceKey {
    static let defaultValue: [TaskStatus: CGRect] = [:]
    static func reduce(value: inout [TaskStatus: CGRect], nextValue: () -> [TaskStatus: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Live state for a card being dragged: where it started (board space), how far it has moved, the
/// status it came from, and a frozen bitmap of the card so the floating copy can never re-layout.
private struct CardDragContext {
    let taskID: TaskItem.ID
    let sourceStatus: TaskStatus
    let originFrame: CGRect
    let snapshot: NSImage?
    var translation: CGSize = .zero
}

struct KanbanBoard: View {
    @ObservedObject var viewModel: BoardViewModel
    var isSidebarHidden = false
    var onToggleSidebar: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    let onCreateTask: () -> Void
    var onCreateProject: () -> Void = {}
    let onEditTask: (TaskItem) -> Void
    let onDeleteTask: (TaskItem) -> Void
    var onRemoveWorktree: (TaskItem) -> Void = { _ in }
    var onArchiveTask: (TaskItem) -> Void = { _ in }
    var onSleepTask: (TaskItem) -> Void = { _ in }
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var columnFrames: [TaskStatus: CGRect] = [:]
    @State private var drag: CardDragContext?
    @State private var dropTarget: TaskStatus?
    /// Edit Lanes mode: column headers are editable in place, hidden lanes show as full columns, and
    /// a dashed column at the end adds one. Only on a project's board (All Projects mixes projects).
    @State private var editingLanes = ProcessInfo.processInfo.environment["BALAGAN_SHOW_LANE_EDITING"] == "1"
    /// A lane being dragged in edit mode: how far it has moved, and its center when the drag began
    /// (its live frame moves with the offset, so it can't be the reference).
    @State private var laneDrag: (id: Lane.ID, dx: CGFloat, startMidX: CGFloat)?
    /// The card the arrow keys have highlighted (⏎ opens it, 1–9 move it, ⌘⌫ archives it).
    // `BALAGAN_SHOW_BOARD_HIGHLIGHT=<task id>` starts with that card highlighted, for a snapshot.
    @State private var keyboardCardID: TaskItem.ID? = ProcessInfo.processInfo.environment["BALAGAN_SHOW_BOARD_HIGHLIGHT"]
    @FocusState private var boardFocused: Bool

    private let boardSpace = "board-canvas"

    /// The visible lanes' card ids, left to right, for arrow-key movement.
    private var navigationColumns: [[TaskItem.ID]] {
        viewModel.boardLanes.filter { $0.collapsed == false }.map { viewModel.tasks(for: $0.status).map(\.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if viewModel.projects.isEmpty {
                WelcomeView(viewModel: viewModel, onCreateProject: onCreateProject)
            } else {
                boardCanvas
                    .focusable()
                    .focused($boardFocused)
                    .focusEffectDisabled()
                    .onAppear { boardFocused = true }
                    .onKeyPress(.upArrow) { moveHighlight(.up) }
                    .onKeyPress(.downArrow) { moveHighlight(.down) }
                    .onKeyPress(.leftArrow) { moveHighlight(.left) }
                    .onKeyPress(.rightArrow) { moveHighlight(.right) }
                    .onKeyPress(.return) { openHighlighted() }
                    .onKeyPress(.escape) {
                        if editingLanes {
                            editingLanes = false
                            return .handled
                        }
                        guard keyboardCardID != nil else { return .ignored }
                        keyboardCardID = nil
                        return .handled
                    }
                    .onKeyPress(.delete, phases: .down) { press in
                        guard press.modifiers.contains(.command), let task = highlightedTask else { return .ignored }
                        onArchiveTask(task)
                        return .handled
                    }
                    .onKeyPress(characters: .decimalDigits) { press in moveHighlighted(toLaneNumber: press.characters) }
                    .onChange(of: navigationColumns) { _, columns in
                        keyboardCardID = BoardKeyboardNavigation.retained(keyboardCardID, columns: columns)
                    }
            }
        }
        .background(Theme.bgWindow)
        .onChange(of: viewModel.selectedProjectID) { _, _ in editingLanes = false }
        .contextMenu {
            Button {
                onCreateTask()
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .disabled(viewModel.projects.isEmpty)

            Button {
                onCreateProject()
            } label: {
                Label("New Project", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                onToggleSidebar()
            } label: {
                Label(isSidebarHidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.leading")
            }

            Button {
                onOpenSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .accessibilityIdentifier("board-context-settings-button")
        }
    }

    private var header: some View {
        HStack {
            Text(viewModel.selectedProjectID.map { viewModel.projectName(for: $0) } ?? "All Projects")
                .font(.system(size: Theme.TextSize.title * balaganUIScale, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer()

            if viewModel.selectedProjectID != nil {
                if editingLanes {
                    Button {
                        editingLanes = false
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: Theme.TextSize.title * balaganUIScale))
                    .help("Finish editing lanes (Esc)")
                    .accessibilityIdentifier("edit-lanes-button")
                } else {
                    Button {
                        editingLanes = true
                    } label: {
                        Label("Edit Lanes", systemImage: "rectangle.split.3x1")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: Theme.TextSize.title * balaganUIScale))
                    .help("Rename, recolor, reorder, hide, add or delete lanes")
                    .accessibilityIdentifier("edit-lanes-button")
                }
            }

            Button {
                onCreateTask()
            } label: {
                Label("Task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: Theme.TextSize.title * balaganUIScale))
            .disabled(viewModel.projects.isEmpty)
            .help("New task")
            .accessibilityIdentifier("create-task-button")
        }
        .padding(16 * balaganUIScale)
    }

    private var boardCanvas: some View {
        GeometryReader { geo in
            // While editing, hidden lanes show as full columns and an Add column follows the last one.
            let count = viewModel.boardLanes.count + (isEditing ? 1 : 0)
            let expandedCount = isEditing ? count : viewModel.boardLanes.filter { $0.collapsed == false }.count
            let collapsedCount = count - expandedCount
            let spacing = 12 * balaganUIScale
            let pad = 16 * balaganUIScale
            let minColumn = 248 * balaganUIScale
            let collapsedWidth = 40 * balaganUIScale
            let available = geo.size.width - pad * 2
                - spacing * CGFloat(max(count - 1, 0))
                - collapsedWidth * CGFloat(collapsedCount)
            let fits = available >= minColumn * CGFloat(max(expandedCount, 1))

            ZStack(alignment: .topLeading) {
                if fits {
                    columnsRow(fixedWidth: nil, spacing: spacing)
                        .padding(.horizontal, pad)
                        .padding(.bottom, pad)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        columnsRow(fixedWidth: minColumn, spacing: spacing)
                            .padding(.horizontal, pad)
                            .padding(.bottom, pad)
                            .frame(height: geo.size.height, alignment: .top)
                    }
                }

                laneDropIndicator

                if let drag, let snapshot = drag.snapshot {
                    // A frozen bitmap of the card, captured once at drag start. Because it never
                    // re-lays-out, the notes can't re-wrap and the height can't oscillate as it moves.
                    Image(nsImage: snapshot)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: snapshot.size.width, height: snapshot.size.height)
                        .scaleEffect(1.03)
                        .shadow(color: Color.black.opacity(0.42), radius: 16, x: 0, y: 11)
                        .offset(
                            x: drag.originFrame.minX + drag.translation.width,
                            y: drag.originFrame.minY + drag.translation.height
                        )
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: boardSpace)
            .onPreferenceChange(ColumnFrameKey.self) { columnFrames = $0 }
        }
    }

    private var isEditing: Bool { editingLanes && viewModel.selectedProjectID != nil }

    private func columnsRow(fixedWidth: CGFloat?, spacing: CGFloat) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(viewModel.boardLanes) { lane in
                if lane.collapsed && isEditing == false {
                    CollapsedLaneColumn(
                        lane: lane,
                        count: viewModel.tasks(for: lane.status).count,
                        onExpand: { toggleLaneCollapsed(lane) }
                    )
                } else {
                    KanbanColumn(
                        lane: lane,
                        tasks: viewModel.tasks(for: lane.status),
                        viewModel: viewModel,
                        boardSpace: boardSpace,
                        draggedTaskID: drag?.taskID,
                        keyboardCardID: keyboardCardID,
                        onHighlightTask: { id in
                            keyboardCardID = id
                            boardFocused = true
                        },
                        isDropTarget: drag != nil && dropTarget == lane.status,
                        onEditTask: onEditTask,
                        onDeleteTask: onDeleteTask,
                        onRemoveWorktree: onRemoveWorktree,
                        onArchiveTask: onArchiveTask,
                        onSleepTask: onSleepTask,
                        onCardDragBegan: { task, frame, snapshot in
                            // Capture exactly once per drag so origin/snapshot never change mid-gesture.
                            guard drag == nil else { return }
                            drag = CardDragContext(
                                taskID: task.id,
                                sourceStatus: task.status,
                                originFrame: frame,
                                snapshot: snapshot
                            )
                            dropTarget = task.status
                        },
                        onCardDragChanged: { translation in
                            guard drag != nil else { return }
                            drag?.translation = translation
                            dropTarget = statusUnderDrag(translation: translation)
                        },
                        onCardDragEnded: { translation in
                            finishDrag(translation: translation)
                        },
                        onRenameLane: { newName in
                            if let projectID = viewModel.selectedProjectID {
                                viewModel.renameLane(projectID: projectID, laneID: lane.id, to: newName)
                            }
                        },
                        onMoveLane: { offset in
                            if let projectID = viewModel.selectedProjectID {
                                viewModel.moveLane(projectID: projectID, laneID: lane.id, by: offset)
                            }
                        },
                        onDeleteLane: {
                            if let projectID = viewModel.selectedProjectID {
                                viewModel.deleteLane(projectID: projectID, laneID: lane.id)
                            }
                        },
                        onCollapseLane: { toggleLaneCollapsed(lane) },
                        canDeleteLane: viewModel.selectedProjectID.map {
                            viewModel.canDeleteLane(projectID: $0, laneID: lane.id)
                        } ?? false,
                        canEditLanes: viewModel.selectedProjectID != nil,
                        isEditing: isEditing,
                        onLaneDragChanged: { dx in
                            let start = laneDrag?.id == lane.id ? laneDrag?.startMidX : columnFrames[lane.status]?.midX
                            if let start { laneDrag = (lane.id, dx, start) }
                        },
                        onLaneDragEnded: { dx in finishLaneDrag(lane, dx: dx) },
                        onRecolorLane: { hex in
                            if let projectID = viewModel.selectedProjectID {
                                viewModel.setLaneColor(projectID: projectID, laneID: lane.id, colorHex: hex)
                            }
                        }
                    )
                    .frame(maxWidth: fixedWidth == nil ? CGFloat.infinity : nil)
                    .frame(width: fixedWidth)
                    // The lane being dragged follows the pointer, lifted above its neighbors.
                    .offset(x: laneDrag?.id == lane.id ? laneDrag?.dx ?? 0 : 0)
                    .zIndex(laneDrag?.id == lane.id ? 1 : 0)
                    .shadow(color: .black.opacity(laneDrag?.id == lane.id ? 0.35 : 0), radius: 14, y: 8)
                }
            }
            if isEditing, let projectID = viewModel.selectedProjectID {
                AddLaneColumn { name in viewModel.addLane(toProjectID: projectID, name: name) }
                    .frame(maxWidth: fixedWidth == nil ? CGFloat.infinity : nil)
                    .frame(width: fixedWidth)
            }
        }
    }

    /// The dragged lane's other lanes, left to right, with their frames on the board.
    private func otherLaneFrames(excluding laneID: Lane.ID) -> [CGRect] {
        viewModel.boardLanes.filter { $0.id != laneID }.compactMap { columnFrames[$0.status] }
    }

    private func laneInsertionIndex(_ laneID: Lane.ID, dx: CGFloat) -> Int? {
        guard let laneDrag, laneDrag.id == laneID else { return nil }
        return LaneReorder.insertionIndex(
            dropX: Double(laneDrag.startMidX + dx),
            otherMidXs: otherLaneFrames(excluding: laneID).map { Double($0.midX) }
        )
    }

    /// An accent line in the gap where the dragged lane would land.
    @ViewBuilder
    private var laneDropIndicator: some View {
        if let laneDrag, let index = laneInsertionIndex(laneDrag.id, dx: laneDrag.dx) {
            let others = otherLaneFrames(excluding: laneDrag.id)
            let gap = 6 * balaganUIScale
            let x = index < others.count ? others[index].minX - gap : (others.last?.maxX ?? 0) + gap
            if let reference = others.first {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3, height: reference.height)
                    .offset(x: x - 1.5, y: reference.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func finishLaneDrag(_ lane: Lane, dx: CGFloat) {
        defer { laneDrag = nil }
        guard let projectID = viewModel.selectedProjectID, let index = laneInsertionIndex(lane.id, dx: dx) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            viewModel.moveLane(projectID: projectID, laneID: lane.id, toIndex: index)
        }
    }

    private var highlightedTask: TaskItem? {
        keyboardCardID.flatMap { id in viewModel.tasks.first { $0.id == id } }
    }

    private func moveHighlight(_ direction: BoardKeyboardNavigation.Direction) -> KeyPress.Result {
        guard let next = BoardKeyboardNavigation.next(from: keyboardCardID, direction: direction, columns: navigationColumns) else {
            return .ignored
        }
        keyboardCardID = next
        return .handled
    }

    private func openHighlighted() -> KeyPress.Result {
        guard let task = highlightedTask else { return .ignored }
        viewModel.select(task: task)
        return .handled
    }

    /// 1–9 moves the highlighted card to that lane (counting every lane, collapsed ones too).
    private func moveHighlighted(toLaneNumber characters: String) -> KeyPress.Result {
        guard let task = highlightedTask, let number = Int(characters), number >= 1,
              viewModel.boardLanes.indices.contains(number - 1) else { return .ignored }
        let status = viewModel.boardLanes[number - 1].status
        guard viewModel.laneAccepts(taskID: task.id, status: status) else {
            NSSound.beep()
            return .handled
        }
        viewModel.move(task: task, to: status)
        return .handled
    }

    private func toggleLaneCollapsed(_ lane: Lane) {
        if let projectID = viewModel.selectedProjectID {
            viewModel.toggleLaneCollapsed(projectID: projectID, laneID: lane.id)
        }
    }

    private func statusUnderDrag(translation: CGSize) -> TaskStatus? {
        guard let drag else { return nil }
        let point = CGPoint(
            x: drag.originFrame.midX + translation.width,
            y: drag.originFrame.midY + translation.height
        )
        return columnFrames.first { $0.value.contains(point) }?.key
    }

    private func finishDrag(translation: CGSize) {
        let target = statusUnderDrag(translation: translation)
        if let drag, let target, target != drag.sourceStatus {
            if viewModel.laneAccepts(taskID: drag.taskID, status: target) {
                viewModel.move(taskID: drag.taskID, to: target)
            } else {
                NSSound.beep()
            }
        }
        drag = nil
        dropTarget = nil
    }
}

private struct KanbanColumn: View {
    let lane: Lane
    let tasks: [TaskItem]
    private var status: TaskStatus { lane.status }
    @ObservedObject var viewModel: BoardViewModel
    let boardSpace: String
    let draggedTaskID: TaskItem.ID?
    var keyboardCardID: TaskItem.ID? = nil
    var onHighlightTask: (TaskItem.ID) -> Void = { _ in }
    let isDropTarget: Bool
    let onEditTask: (TaskItem) -> Void
    let onDeleteTask: (TaskItem) -> Void
    var onRemoveWorktree: (TaskItem) -> Void = { _ in }
    var onArchiveTask: (TaskItem) -> Void = { _ in }
    var onSleepTask: (TaskItem) -> Void = { _ in }
    let onCardDragBegan: (TaskItem, CGRect, NSImage?) -> Void
    let onCardDragChanged: (CGSize) -> Void
    let onCardDragEnded: (CGSize) -> Void
    var onRenameLane: (String) -> Void = { _ in }
    var onMoveLane: (Int) -> Void = { _ in }
    var onDeleteLane: () -> Void = {}
    var onCollapseLane: () -> Void = {}
    var canDeleteLane = true
    var canEditLanes = false
    var isEditing = false
    var onLaneDragChanged: (CGFloat) -> Void = { _ in }
    var onLaneDragEnded: (CGFloat) -> Void = { _ in }
    var onRecolorLane: (String) -> Void = { _ in }
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFieldFocused: Bool

    private func beginRename() {
        draftName = lane.name
        isRenaming = true
        renameFieldFocused = true
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { onRenameLane(trimmed) }
        isRenaming = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * balaganUIScale) {
            if isEditing {
                EditableLaneHeader(
                    lane: lane,
                    count: tasks.count,
                    canDelete: canDeleteLane,
                    boardSpace: boardSpace,
                    onRename: onRenameLane,
                    onRecolor: onRecolorLane,
                    onDragChanged: onLaneDragChanged,
                    onDragEnded: onLaneDragEnded,
                    onToggleHidden: onCollapseLane,
                    onDelete: onDeleteLane
                )
                .frame(height: 28 * balaganUIScale)
            } else {
            HStack(spacing: 7 * balaganUIScale) {
                Circle()
                    .fill(lane.color)
                    .frame(width: 7 * balaganUIScale, height: 7 * balaganUIScale)
                if isRenaming {
                    TextField("Lane name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($renameFieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .accessibilityIdentifier("column-rename-field")
                } else {
                    Text(lane.name)
                        .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("column-\(status.accessibilitySlug)")
                }
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .medium, design: .rounded))
                    .foregroundStyle(lane.color)
                    .padding(.horizontal, 6 * balaganUIScale)
                    .padding(.vertical, 1 * balaganUIScale)
                    .background(lane.color.opacity(0.16), in: Capsule())
            }
            .frame(height: 28 * balaganUIScale)
            .padding(.horizontal, 2 * balaganUIScale)
            .contextMenu {
                if canEditLanes {
                    Button("Rename Lane") { beginRename() }
                        .accessibilityIdentifier("lane-rename-\(status.accessibilitySlug)")
                    Button("Move Left") { onMoveLane(-1) }
                    Button("Move Right") { onMoveLane(1) }
                    Button("Hide Lane") { onCollapseLane() }
                    Divider()
                    Button("Delete Lane", role: .destructive) { onDeleteLane() }
                        .disabled(canDeleteLane == false)
                }
            }
            }

            if tasks.isEmpty {
                EmptyColumn()
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 8 * balaganUIScale) {
                            ForEach(tasks) { task in
                                card(for: task)
                                    .id(task.id)
                            }
                        }
                        .padding(.bottom, 4 * balaganUIScale)
                        // While lanes are being edited the cards are scenery: dimmed and inert.
                        .opacity(isEditing ? 0.45 : 1)
                        .allowsHitTesting(isEditing == false)
                    }
                    .scrollDisabled(draggedTaskID != nil)
                    .onChange(of: keyboardCardID) { _, id in
                        guard let id, tasks.contains(where: { $0.id == id }) else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(10 * balaganUIScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .stroke(isDropTarget ? Theme.accent : Theme.hairline, lineWidth: isDropTarget ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ColumnFrameKey.self,
                    value: [status: proxy.frame(in: .named(boardSpace))]
                )
            }
        )
    }

    /// One task card. Extracted from the `ForEach` so the large `TaskCard` initializer type-checks in
    /// reasonable time (the compiler times out on it inlined) and the sleep gating reads clearly.
    @ViewBuilder
    private func card(for task: TaskItem) -> some View {
        let sleepAction: (() -> Void)? = viewModel.canSleepTask(taskID: task.id)
            ? { onSleepTask(task) }
            : nil
        ZStack(alignment: .topTrailing) {
            TaskCard(
                task: task,
                projectName: viewModel.projectName(for: task.projectID),
                isSelected: task.id == viewModel.selectedTaskID,
                isDragged: task.id == draggedTaskID,
                boardSpace: boardSpace,
                onSelect: { viewModel.select(task: task) },
                onHighlight: { onHighlightTask(task.id) },
                onEdit: { onEditTask(task) },
                onDelete: { onDeleteTask(task) },
                onRemoveWorktree: { onRemoveWorktree(task) },
                onArchive: { onArchiveTask(task) },
                onSleep: sleepAction,
                isAsleep: viewModel.taskIsDormant(task),
                sleepReason: viewModel.dormantReason(task),
                onWake: viewModel.taskIsDormant(task) && viewModel.canWakeInBackground
                    ? { viewModel.wakeInBackground(taskID: task.id) }
                    : nil,
                pullRequest: viewModel.pullRequests[task.id],
                onMove: { nextStatus in viewModel.move(task: task, to: nextStatus) },
                onDragBegan: { frame, snapshot in
                    onCardDragBegan(task, frame, snapshot)
                },
                onDragChanged: onCardDragChanged,
                onDragEnded: onCardDragEnded,
                needsAttention: viewModel.taskNeedsAttention(task),
                isRunning: viewModel.taskIsRunning(task),
                isWaiting: viewModel.taskIsWaiting(task),
                worktree: viewModel.worktreeInfo(for: task),
                activity: viewModel.taskActivity(task),
                isKeyboardFocused: task.id == keyboardCardID,
                ports: viewModel.devServerPorts[task.id] ?? [],
                tokens: viewModel.taskTokenUsage[task.id],
                savedPrompts: viewModel.savedPrompts(for: task),
                promptBlocker: viewModel.agentSendBlocker(taskID: task.id),
                onSendPrompt: { prompt in
                    if viewModel.sendToAgent(taskID: task.id, text: prompt.text) == false { NSSound.beep() }
                },
                moveLanes: viewModel.lanes(forProjectID: task.projectID)
            )

            TaskStatusAccessibilityMarker(task: task)
        }
    }
}

/// A collapsed lane: a thin strip showing the lane's color, a vertical label and its count. Clicking it
/// expands the lane back to a full column.
private struct CollapsedLaneColumn: View {
    let lane: Lane
    let count: Int
    let onExpand: () -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 10 * balaganUIScale) {
                Circle()
                    .fill(lane.color)
                    .frame(width: 7 * balaganUIScale, height: 7 * balaganUIScale)
                Text("\(count)")
                    .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .medium, design: .rounded))
                    .foregroundStyle(lane.color)
                Text(lane.name)
                    .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(height: 120 * balaganUIScale)   // reserve room for the rotated label
                Spacer()
            }
            .frame(width: 40 * balaganUIScale)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 10 * balaganUIScale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(lane.color.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Expand \(lane.name)")
        .accessibilityIdentifier("collapsed-lane-\(lane.status.accessibilitySlug)")
    }
}

private struct EmptyColumn: View {
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        Text("No tasks")
            .font(.system(size: Theme.TextSize.body * balaganUIScale))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 76 * balaganUIScale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .accessibilityIdentifier("empty-column")
    }
}
