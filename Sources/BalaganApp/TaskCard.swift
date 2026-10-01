import AppKit
import SwiftUI
import BalaganCore

/// Board-space frame of a single card, captured so a lifted drag can start exactly where it sat.
private struct CardFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct TaskStatusAccessibilityMarker: View {
    let task: TaskItem

    var body: some View {
        Text(task.status.displayName)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityLabel("\(task.title) \(task.status.displayName)")
            .accessibilityIdentifier("task-card-\(task.title.accessibilitySlug)-status-\(task.status.accessibilitySlug)")
    }
}

/// Pure visual for a task card — shared by the in-column card and the snapshot taken for the lifted
/// drag preview, so the thing you drag is pixel-identical to where it came from.
private struct TaskCardBody: View {
    let task: TaskItem
    let projectName: String
    var isSelected = false
    var isHovered = false
    var drawShadow = true
    var needsAttention = false
    var isRunning = false
    var isWaiting = false
    var worktree: TaskWorktreeInfo? = nil
    var pullRequest: TaskPullRequest? = nil
    var activity: TaskActivity? = nil
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * balaganUIScale) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * balaganUIScale) {
                // Running > waiting > finished, resolved by the shared `AgentStatusGlyph` so the card,
                // the sidebar and the tab strip all say the same thing about the same agent.
                if let glyph = AgentStatusGlyph.resolve(
                    isRunning: isRunning,
                    isWaiting: isWaiting,
                    needsAttention: needsAttention
                ) {
                    AgentStatusIndicator(glyph: glyph, size: Theme.TextSize.body * balaganUIScale)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                }
                Text(task.title)
                    .font(.system(size: Theme.TextSize.title * balaganUIScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                // Only High is worth a mark: when every card says "MEDIUM", none of them says anything.
                if task.priority == .high {
                    PriorityBadge(priority: task.priority)
                }
            }

            Text(projectName)
                .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            if let worktree {
                let live = Color(red: 0.25, green: 0.73, blue: 0.44)
                let gone = Color(red: 0.86, green: 0.45, blue: 0.43)
                HStack(spacing: 5 * balaganUIScale) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5 * balaganUIScale, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(worktree.branch)
                        .foregroundStyle(Theme.textSecondary)
                        .strikethrough(!worktree.exists, color: gone)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Circle()
                        .fill(worktree.exists ? live : gone)
                        .frame(width: 5 * balaganUIScale, height: 5 * balaganUIScale)
                    Text(worktree.exists ? "live" : "deleted")
                        .foregroundStyle(worktree.exists ? live : gone)
                }
                .font(.system(size: Theme.TextSize.micro * balaganUIScale, weight: .medium))
                .help(worktree.exists
                    ? "Worktree: \(worktree.path)"
                    : "Worktree removed (was: \(worktree.path))")
            }

            if let pullRequest {
                TaskCardPRBadge(pullRequest: pullRequest, scale: balaganUIScale)
            }

            if let activity {
                TaskCardActivity(activity: activity, scale: balaganUIScale)
            }

            if task.notes.isEmpty == false {
                // The live activity is the fresher story; the notes you wrote at creation step back.
                Text(task.notes)
                    .font(.system(size: Theme.TextSize.small * balaganUIScale))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(activity == nil ? 3 : 1)
            }

            TagRow(tags: task.tags)
        }
        .padding(.vertical, 9 * balaganUIScale)
        .padding(.horizontal, 11 * balaganUIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accentSoft : (isHovered ? Theme.surfaceHover : Theme.surfaceRaised))
        .overlay(alignment: .leading) {
            SelectionAccentBar(isSelected: isSelected, verticalInset: 4 * balaganUIScale)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .shadow(
            color: Color.black.opacity(drawShadow ? 0.18 : 0),
            radius: drawShadow ? 1.5 : 0,
            x: 0,
            y: drawShadow ? 1 : 0
        )
    }
}

struct TaskCard: View {
    let task: TaskItem
    let projectName: String
    let isSelected: Bool
    let isDragged: Bool
    let boardSpace: String
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onRemoveWorktree: () -> Void = {}
    var onArchive: () -> Void = {}
    /// Non-nil only when the task has live terminals to sleep; nil hides the "Sleep" menu item.
    var onSleep: (() -> Void)? = nil
    var isAsleep = false
    /// Why it went to sleep on its own, if it did ("Slept after 30m idle").
    var sleepReason: String? = nil
    /// Non-nil on a dormant task: starts its terminals in the background without opening it.
    var onWake: (() -> Void)? = nil
    var pullRequest: TaskPullRequest? = nil
    let onMove: (TaskStatus) -> Void
    let onDragBegan: (CGRect, NSImage?) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    var needsAttention = false
    var isRunning = false
    var isWaiting = false
    var worktree: TaskWorktreeInfo? = nil
    var activity: TaskActivity? = nil
    /// The board's lanes, offered in the card's "Move To" menu.
    var moveLanes: [Lane] = Lane.defaults
    @Environment(\.balaganUIScale) private var balaganUIScale
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false
    @State private var frameInBoard: CGRect = .zero
    @State private var isDraggingActive = false

    /// Render the card to a bitmap so the floating drag copy is frozen (no re-layout, no jitter).
    /// Use the card's resting appearance (not hover) so lifting it doesn't shift its color — the
    /// lift reads through the shadow + scale on the floating image instead.
    @MainActor private func makeDragSnapshot() -> NSImage? {
        guard frameInBoard.width > 1 else { return nil }
        let renderer = ImageRenderer(
            content: TaskCardBody(task: task, projectName: projectName, isSelected: isSelected, drawShadow: false, worktree: worktree, pullRequest: pullRequest, activity: activity)
                .frame(width: frameInBoard.width)
                .environment(\.balaganUIScale, balaganUIScale)
                // ImageRenderer defaults to a light appearance; force dark so the dynamic label
                // colors resolve to white (matching the live dark UI) instead of black.
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = displayScale
        renderer.isOpaque = false
        return renderer.nsImage
    }

    var body: some View {
        TaskCardBody(task: task, projectName: projectName, isSelected: isSelected, isHovered: isHovered, needsAttention: needsAttention, isRunning: isRunning, isWaiting: isWaiting, worktree: worktree, pullRequest: pullRequest, activity: activity)
            // While lifted, the in-place card becomes a dashed placeholder that keeps the column's layout.
            // A slept task is dimmed to read as inactive.
            .opacity(isDragged ? 0 : (isAsleep ? 0.6 : 1))
            .overlay(alignment: .topTrailing) {
                if isAsleep {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(7 * balaganUIScale)
                        .help("\(sleepReason ?? "Not running") — open or right-click → Wake")
                        .accessibilityIdentifier("task-card-asleep-indicator")
                }
            }
            .overlay {
                if isDragged {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(Theme.bgWindow.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                                .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: CardFrameKey.self, value: proxy.frame(in: .named(boardSpace)))
                }
            )
            .onPreferenceChange(CardFrameKey.self) { frameInBoard = $0 }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.14), value: isDragged)
            .onHover { isHovered = $0 }
            .onTapGesture(count: 2, perform: onSelect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(boardSpace))
                    .onChanged { value in
                        if isDraggingActive == false {
                            isDraggingActive = true
                            onDragBegan(frameInBoard, makeDragSnapshot())
                        }
                        onDragChanged(value.translation)
                    }
                    .onEnded { value in
                        isDraggingActive = false
                        onDragEnded(value.translation)
                    }
            )
            .contextMenu {
                Button {
                    onEdit()
                } label: {
                    Label("Edit Task", systemImage: "pencil")
                }
                .accessibilityIdentifier("task-context-edit-button")

                Menu("Move To") {
                    ForEach(moveLanes) { lane in
                        Button(lane.name) {
                            onMove(lane.status)
                        }
                        .disabled(lane.status == task.status)
                        .accessibilityIdentifier("task-context-move-\(lane.status.accessibilitySlug)")
                    }
                }
                .accessibilityIdentifier("task-context-move-menu")

                Divider()

                if let onWake {
                    Button {
                        onWake()
                    } label: {
                        Label("Wake", systemImage: "sun.max")
                    }
                    .accessibilityIdentifier("task-context-wake-button")
                }
                if let onSleep {
                    Button {
                        onSleep()
                    } label: {
                        Label("Sleep", systemImage: "moon.zzz")
                    }
                    .accessibilityIdentifier("task-context-sleep-button")
                }

                Button {
                    onArchive()
                } label: {
                    Label("Archive Task", systemImage: "archivebox")
                }
                .accessibilityIdentifier("task-context-archive-button")

                if task.branchOrWorktree?.nilIfBlank != nil {
                    Button {
                        onRemoveWorktree()
                    } label: {
                        Label("Remove Worktree", systemImage: "trash.slash")
                    }
                    .accessibilityIdentifier("task-context-remove-worktree-button")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Task", systemImage: "trash")
                }
                .accessibilityIdentifier("task-context-delete-button")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onSelect)
            .accessibilityIdentifier("task-card-\(task.title.accessibilitySlug)")
    }
}

/// The card's live agent row: "Waiting 4m · <summary>", then a quoted preview of what the agent
/// last said. The elapsed time re-renders on its own every 30 s.
private struct TaskCardActivity: View {
    let activity: TaskActivity
    let scale: CGFloat

    private var stateColor: Color {
        switch activity.lifecycle {
        case .needsInput: return Theme.agentWaiting
        case .running: return Theme.accent
        case .idle, nil: return Theme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let label = activity.stateLabel(now: context.date)
                if label != nil || activity.summary != nil {
                    HStack(spacing: 5 * scale) {
                        if let label {
                            Text(label)
                                .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                                .foregroundStyle(stateColor)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        if label != nil, activity.summary != nil {
                            Text("·").foregroundStyle(Theme.textTertiary)
                        }
                        if let summary = activity.summary {
                            Text(summary)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: Theme.TextSize.micro * scale, weight: .medium))
                }
            }

            if let response = activity.visibleLastResponse {
                Text(response)
                    .font(.system(size: Theme.TextSize.small * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, 7 * scale)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(activity.lifecycle == .needsInput ? Theme.agentWaiting.opacity(0.7) : Theme.hairlineStrong)
                            .frame(width: 2 * scale)
                    }
                    .help(response)
            }
        }
        .accessibilityIdentifier("task-card-activity")
    }
}

/// A small red flag for high-priority work (the only priority the card marks).
private struct PriorityBadge: View {
    let priority: TaskPriority
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: Theme.TextSize.micro * balaganUIScale, weight: .semibold))
            .foregroundStyle(priority.tint)
            .help("\(priority.displayName) priority")
            .accessibilityLabel("\(priority.displayName) priority")
            .accessibilityIdentifier("priority-\(priority.rawValue.lowercased())")
    }
}

/// Tags as quiet text ("#ui #fixtures") rather than chips — metadata, not the point of the card.
private struct TagRow: View {
    let tags: [String]
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        if tags.isEmpty == false {
            Text(tags.map { "#\($0)" }.joined(separator: "  "))
                .font(.system(size: Theme.TextSize.micro * balaganUIScale, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
