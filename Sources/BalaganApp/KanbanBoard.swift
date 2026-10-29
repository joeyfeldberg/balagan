import AppKit
import SwiftUI
import BalaganCore

/// Board-space frame of each kanban column, used to resolve a drag's drop target by hit-testing.
struct ColumnFrameKey: PreferenceKey {
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
    /// The full New Task form, preset to a lane (used on All Projects, where a lane has no single project).
    var onCreateTaskInLane: (TaskStatus) -> Void = { _ in }
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var columnFrames: [TaskStatus: CGRect] = [:]
    @State private var drag: CardDragContext?
    @State private var dropTarget: TaskStatus?
    /// A lane being dragged by its header: how far it has moved, and its center when the drag began
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

    /// Lanes share the board's width, between these bounds: a few lanes fill most of a wide window
    /// without getting absurdly wide, and past the minimum the board scrolls sideways instead of
    /// squeezing them.
    static let laneWidth: CGFloat = 272
    static let maxLaneWidth: CGFloat = 380
    /// About what the collapsed "+ Lane" button takes; it sizes to its label.
    private static let addLaneButtonAllowance: CGFloat = 80

    /// The width every visible lane gets for a board this wide.
    private func laneWidth(boardWidth: CGFloat, spacing: CGFloat, pad: CGFloat) -> CGFloat {
        let visible = CGFloat(max(viewModel.boardLanes.filter { $0.collapsed == false }.count, 1))
        let hasHidden = viewModel.boardLanes.contains(where: \.collapsed)
        // Room taken by the "+ Lane" button and the Hidden stack, which keep their own size.
        let extras = (viewModel.selectedProjectID != nil ? Self.addLaneButtonAllowance * balaganUIScale + spacing : 0)
            + (hasHidden ? HiddenLanesStack.width * balaganUIScale + spacing : 0)
        let share = (boardWidth - pad * 2 - extras - spacing * (visible - 1)) / visible
        return min(max(share, Self.laneWidth * balaganUIScale), Self.maxLaneWidth * balaganUIScale)
    }

    private var boardCanvas: some View {
        GeometryReader { geo in
            let spacing = 20 * balaganUIScale
            let pad = 16 * balaganUIScale

            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal, showsIndicators: true) {
                    columnsRow(fixedWidth: laneWidth(boardWidth: geo.size.width, spacing: spacing, pad: pad), spacing: spacing)
                        .padding(.horizontal, pad)
                        .padding(.bottom, pad)
                        .frame(height: geo.size.height, alignment: .top)
                }
                .scrollDisabled(drag != nil || laneDrag != nil)

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

    private func columnsRow(fixedWidth: CGFloat, spacing: CGFloat) -> some View {
        let visible = viewModel.boardLanes.filter { $0.collapsed == false }
        let hidden = viewModel.boardLanes.filter(\.collapsed)
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(visible) { lane in
                column(for: lane, isFirst: lane.id == visible.first?.id, isLast: lane.id == visible.last?.id)
                    .frame(width: fixedWidth)
                    // The lane being dragged follows the pointer, lifted above its neighbors.
                    .offset(x: laneDrag?.id == lane.id ? laneDrag?.dx ?? 0 : 0)
                    .zIndex(laneDrag?.id == lane.id ? 1 : 0)
                    .shadow(color: .black.opacity(laneDrag?.id == lane.id ? 0.35 : 0), radius: 14, y: 8)
            }
            if let projectID = viewModel.selectedProjectID {
                AddLaneButton { name in viewModel.addLane(toProjectID: projectID, name: name) }
            }
            if hidden.isEmpty == false {
                HiddenLanesStack(
                    lanes: hidden,
                    counts: Dictionary(uniqueKeysWithValues: hidden.map { ($0.id, viewModel.tasks(for: $0.status).count) }),
                    dropTarget: drag != nil ? dropTarget : nil,
                    boardSpace: boardSpace,
                    onShow: { toggleLaneCollapsed($0) }
                )
            }
        }
    }

    /// One visible lane, with everything its header can do.
    private func column(for lane: Lane, isFirst: Bool, isLast: Bool) -> some View {
        let projectID = viewModel.selectedProjectID
        var actions = LaneActions()
        actions.canEdit = projectID != nil
        actions.isFirst = isFirst
        actions.isLast = isLast
        if let projectID {
            let count = viewModel.laneTaskCount(projectID: projectID, laneID: lane.id)
            actions.deleteBlocker = viewModel.canDeleteLane(projectID: projectID, laneID: lane.id)
                ? nil
                : (count > 0 ? "move its \(count.counted("task")) out first" : "a board needs one lane")
            actions.onRename = { viewModel.renameLane(projectID: projectID, laneID: lane.id, to: $0) }
            actions.onRecolor = { viewModel.setLaneColor(projectID: projectID, laneID: lane.id, colorHex: $0) }
            actions.onMove = { offset in
                withAnimation(.easeOut(duration: 0.18)) { viewModel.moveLane(projectID: projectID, laneID: lane.id, by: offset) }
            }
            actions.onHide = { viewModel.toggleLaneCollapsed(projectID: projectID, laneID: lane.id) }
            actions.onDelete = { viewModel.deleteLane(projectID: projectID, laneID: lane.id) }
            actions.onDragChanged = { dx in
                let start = laneDrag?.id == lane.id ? laneDrag?.startMidX : columnFrames[lane.status]?.midX
                if let start { laneDrag = (lane.id, dx, start) }
            }
            actions.onDragEnded = { dx in finishLaneDrag(lane, dx: dx) }
        }
        return KanbanColumn(
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
                drag = CardDragContext(taskID: task.id, sourceStatus: task.status, originFrame: frame, snapshot: snapshot)
                dropTarget = task.status
            },
            onCardDragChanged: { translation in
                guard drag != nil else { return }
                drag?.translation = translation
                dropTarget = statusUnderDrag(translation: translation)
            },
            onCardDragEnded: { translation in finishDrag(translation: translation) },
            laneActions: actions,
            quickAdd: projectID.map { projectID in
                { title in viewModel.quickAddTask(projectID: projectID, title: title, status: lane.status) }
            },
            onCreateTaskInLane: { onCreateTaskInLane(lane.status) }
        )
    }

    /// The dragged lane's other lanes, left to right, with their frames on the board.
    private func otherLaneFrames(excluding laneID: Lane.ID) -> [CGRect] {
        viewModel.boardLanes.filter { $0.id != laneID }.compactMap { columnFrames[$0.status] }
    }

    private func laneInsertionIndex(_ laneID: Lane.ID, dx: CGFloat) -> Int? {
        guard let laneDrag, laneDrag.id == laneID else { return nil }
        return DragReorder.insertionIndex(
            dropAt: Double(laneDrag.startMidX + dx),
            otherMidpoints: otherLaneFrames(excluding: laneID).map { Double($0.midX) }
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
        keyboardCardID.flatMap { id in viewModel.task(for: id) }
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
    var laneActions = LaneActions()
    /// Creates a task with just a title in this lane; nil on All Projects, which opens the form instead.
    var quickAdd: ((String) -> Void)? = nil
    var onCreateTaskInLane: () -> Void = {}
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var addingTask = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * balaganUIScale) {
            LaneHeader(lane: lane, count: tasks.count, actions: headerActions, boardSpace: boardSpace)

            // Cards, then "+ Add task" right after the last one, all in the lane's own scroll area.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8 * balaganUIScale) {
                        if tasks.isEmpty, addingTask == false {
                            EmptyColumn()
                        }
                        ForEach(tasks) { task in
                            card(for: task)
                                .id(task.id)
                        }
                        quickAddRow
                    }
                    .padding(.bottom, 4 * balaganUIScale)
                }
                .scrollDisabled(draggedTaskID != nil)
                .onChange(of: keyboardCardID) { _, id in
                    guard let id, tasks.contains(where: { $0.id == id }) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        // Open lanes: no box, just the header and the cards on the board (as on Linear), so a lane with
        // two cards isn't a tall empty rectangle. A card dragged over a lane tints it.
        .padding(.vertical, 6 * balaganUIScale)
        .padding(.horizontal, 4 * balaganUIScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .fill(isDropTarget ? Theme.accent.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .stroke(Theme.accent.opacity(isDropTarget ? 0.5 : 0), lineWidth: 1.5)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ColumnFrameKey.self,
                    value: [status: proxy.frame(in: .named(boardSpace))]
                )
            }
        )
    }

    /// "+ Add task": an inline title field on a project's board; the full form on All Projects.
    @ViewBuilder
    private var quickAddRow: some View {
        if let quickAdd {
            QuickAddTask(isOpen: $addingTask, onAdd: quickAdd)
        } else {
            Button(action: onCreateTaskInLane) {
                Label("Add task", systemImage: "plus")
                    .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4 * balaganUIScale)
                    .padding(.vertical, 5 * balaganUIScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quick-add-task-button")
        }
    }

    /// The header's actions, with "add a task" opening the inline field (or the form on All Projects).
    private var headerActions: LaneActions {
        var actions = laneActions
        actions.onAddTask = { if quickAdd != nil { addingTask = true } else { onCreateTaskInLane() } }
        return actions
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
                onSendPrompt: { viewModel.sendPrompt($0, taskID: task.id) },
                moveLanes: viewModel.lanes(forProjectID: task.projectID)
            )

            TaskStatusAccessibilityMarker(task: task)
        }
    }
}

/// Hidden lanes, gathered in one stack after the last lane (as Linear does) instead of strips between
/// the lanes. A row shows the lane again on click, and is a drop target, so a card can still be moved
/// into a hidden lane.
private struct HiddenLanesStack: View {
    static let width: CGFloat = 170
    let lanes: [Lane]
    let counts: [Lane.ID: Int]
    let dropTarget: TaskStatus?
    let boardSpace: String
    let onShow: (Lane) -> Void
    @Environment(\.balaganUIScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text("HIDDEN · \(lanes.count)")
                .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .frame(height: 28 * scale)
            ForEach(lanes) { lane in
                Button { onShow(lane) } label: {
                    HStack(spacing: 7 * scale) {
                        Circle().fill(lane.color).frame(width: 7 * scale, height: 7 * scale)
                        Text(lane.name)
                            .font(.system(size: Theme.TextSize.body * scale, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4 * scale)
                        Text("\(counts[lane.id] ?? 0)")
                            .font(.system(size: Theme.TextSize.small * scale).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8 * scale)
                    .padding(.vertical, 7 * scale)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusButton).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusButton)
                            .stroke(dropTarget == lane.status ? Theme.accent : Theme.hairline, lineWidth: dropTarget == lane.status ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(lane.name) on the board")
                .accessibilityIdentifier("hidden-lane-\(lane.status.accessibilitySlug)")
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ColumnFrameKey.self, value: [lane.status: proxy.frame(in: .named(boardSpace))])
                    }
                )
            }
        }
        .padding(.vertical, 6 * scale)
        .padding(.horizontal, 4 * scale)
        .frame(width: Self.width * scale, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
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
