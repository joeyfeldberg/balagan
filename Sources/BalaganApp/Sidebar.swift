import SwiftUI
import BalaganCore

/// Sidebar-space frames of each project row, used to resolve drag-to-reorder drop position.
private struct ProjectRowFrameKey: PreferenceKey {
    static let defaultValue: [Project.ID: CGRect] = [:]
    static func reduce(value: inout [Project.ID: CGRect], nextValue: () -> [Project.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct Sidebar: View {
    @ObservedObject var viewModel: BoardViewModel
    let onCreateProject: () -> Void
    let onEditProject: (Project) -> Void
    let onDeleteProject: (Project) -> Void
    let onShowAllProjects: () -> Void
    let onShowProject: (Project) -> Void
    var onShowArchived: () -> Void = {}
    let onOpenProjectTerminals: (Project) -> Void
    let onOpenSettings: () -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var projectFrames: [Project.ID: CGRect] = [:]
    @State private var dragProjectID: Project.ID?
    @State private var dragStartFrame: CGRect = .zero
    @State private var dropIndex: Int?
    @GestureState private var dragTranslation: CGSize = .zero

    private let projectsSpace = "sidebar-projects"

    /// The project rows are board filters, so they only read as "selected" on the board. Inside a
    /// task, the task's own row is the you-are-here marker.
    private var isOnBoard: Bool {
        viewModel.selectedTaskID == nil && viewModel.showingArchived == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No big title or button row: the sidebar starts with content. Project actions live on the
            // Projects header below.
            Color.clear.frame(height: 10 * balaganUIScale)

            ScrollView {
                VStack(alignment: .leading, spacing: 6 * balaganUIScale) {
                    SidebarProjectButton(
                        title: "All Projects",
                        subtitle: "\(viewModel.boardTasks.count) tasks",
                        isSelected: viewModel.selectedProjectID == nil && isOnBoard
                    ) {
                        onShowAllProjects()
                    }
                    .accessibilityIdentifier("project-filter-all")

                    if viewModel.agentsNeedingYouCount > 0 {
                        needsYouRow(count: viewModel.agentsNeedingYouCount)
                    }

                    projectsHeader

                    ForEach(viewModel.projects) { project in
                        projectGroup(project)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .coordinateSpace(name: projectsSpace)
                .onPreferenceChange(ProjectRowFrameKey.self) { projectFrames = $0 }
                .overlay(alignment: .topLeading) { reorderInsertionLine }
                .overlay(alignment: .topLeading) { reorderDragPreview }
            }
            .scrollDisabled(dragProjectID != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            if viewModel.agentUsage.isEmpty == false {
                SidebarUsageMeter(usage: viewModel.agentUsage)
                Divider()
            }

            Button {
                onShowArchived()
            } label: {
                HStack(spacing: 8 * balaganUIScale) {
                    Label("Archived", systemImage: "archivebox")
                    Spacer()
                    if viewModel.archivedTasks.isEmpty == false {
                        Text("\(viewModel.archivedTasks.count)")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .font(.system(size: Theme.TextSize.title * balaganUIScale))
            .foregroundStyle(viewModel.showingArchived ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, 14 * balaganUIScale)
            .padding(.vertical, 9 * balaganUIScale)
            .background(viewModel.showingArchived ? Theme.accentSoft : Color.clear)
            .help("Archived tasks")
            .accessibilityIdentifier("archived-filter-button")

            Button {
                onOpenSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .font(.system(size: Theme.TextSize.title * balaganUIScale))
            .padding(.horizontal, 14 * balaganUIScale)
            .padding(.vertical, 10 * balaganUIScale)
            .help("Open settings")
            .accessibilityIdentifier("settings-button")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    /// "PROJECTS" with the project actions at its right: edit the selected project, add one.
    private var projectsHeader: some View {
        HStack(spacing: 10 * balaganUIScale) {
            Text("PROJECTS")
                .font(.system(size: Theme.TextSize.micro * balaganUIScale, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            if let selectedProjectID = viewModel.selectedProjectID,
               let project = viewModel.project(for: selectedProjectID) {
                Button {
                    onEditProject(project)
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit \(project.name)")
                .accessibilityIdentifier("edit-project-button")
            }
            Button {
                onCreateProject()
            } label: {
                Image(systemName: "plus")
            }
            .help("New project")
            .accessibilityIdentifier("create-project-button")
        }
        .buttonStyle(.borderless)
        .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 22 * balaganUIScale)
        .padding(.trailing, 18 * balaganUIScale)
        .padding(.top, 12 * balaganUIScale)
        .padding(.bottom, 2 * balaganUIScale)
    }

    /// A project row plus, unless collapsed, its tasks. The whole group is the unit the project
    /// drag-reorder measures and hides, so a dragged project takes its tasks with it.
    @ViewBuilder
    private func projectGroup(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 1 * balaganUIScale) {
            projectRow(project)
            if project.sidebarCollapsed == false {
                ForEach(viewModel.sidebarTasks(for: project)) { task in
                    taskRow(task, in: project)
                }
            }
        }
        .opacity(dragProjectID == project.id ? 0 : 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ProjectRowFrameKey.self,
                    value: [project.id: proxy.frame(in: .named(projectsSpace))]
                )
            }
        )
    }

    private func taskRow(_ task: TaskItem, in project: Project) -> some View {
        let activity = viewModel.taskActivity(task)
        return SidebarTaskRow(
            title: task.title,
            laneColor: project.lanes.first { $0.status == task.status }?.color ?? Theme.textTertiary,
            agentStatus: AgentStatusGlyph.resolve(
                isRunning: viewModel.taskIsRunning(task),
                isWaiting: viewModel.taskIsWaiting(task),
                needsAttention: viewModel.taskNeedsAttention(task)
            ),
            waitingSince: activity?.lifecycle == .needsInput ? activity?.since : nil,
            isSelected: viewModel.selectedTaskID == task.id,
            isAsleep: viewModel.taskIsDormant(task),
            dormantReason: viewModel.taskIsDormant(task) ? viewModel.dormantReason(task) : nil
        ) {
            viewModel.select(task: task)
        }
        .accessibilityIdentifier("sidebar-task-\(task.id)")
    }

    /// The project row's glyph. Collapsed, it's the aggregate over every task. Expanded, each task row
    /// carries its own, so the project only speaks for its hidden Terminals workspace (no row of its own).
    private func projectGlyph(_ project: Project, agentState: TaskAgentState, isExpanded: Bool) -> AgentStatusGlyph? {
        guard isExpanded else {
            return AgentStatusGlyph.resolve(
                isRunning: agentState == .running,
                isWaiting: agentState == .needsInput,
                needsAttention: viewModel.projectNeedsAttention(project.id)
            )
        }
        guard let terminals = viewModel.tasks.first(where: { $0.id == "project-terminals-\(project.id)" }) else {
            return nil
        }
        return AgentStatusGlyph.resolve(
            isRunning: viewModel.taskIsRunning(terminals),
            isWaiting: viewModel.taskIsWaiting(terminals),
            needsAttention: viewModel.taskNeedsAttention(terminals)
        )
    }

    /// "2 agents need you  ⌘J" — the clickable face of the next-agent jump.
    private func needsYouRow(count: Int) -> some View {
        let chord = viewModel.keyboardShortcuts.chord(for: .nextAgentNeedingYou).displayString
        return Button {
            viewModel.jumpToNextAgentNeedingYou()
        } label: {
            HStack(spacing: 7 * balaganUIScale) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(Theme.agentWaiting)
                Text(count == 1 ? "1 agent needs you" : "\(count) agents need you")
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Text(chord)
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .medium))
            .padding(.horizontal, 12 * balaganUIScale)
            .padding(.vertical, 7 * balaganUIScale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .fill(Theme.agentWaiting.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .stroke(Theme.agentWaiting.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8 * balaganUIScale)
        .padding(.top, 6 * balaganUIScale)
        .help("Open the next agent waiting on you (\(chord))")
        .accessibilityIdentifier("sidebar-needs-you")
    }

    /// A project row, draggable to reorder. The dragged row is hidden in place while a floating copy
    /// follows the cursor and an accent line shows where it will land.
    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        // Aggregate of the project's tasks, same precedence as a card: a project with any working
        // agent spins; otherwise any waiting agent shows the amber question mark; otherwise the
        // finished-off-screen dot.
        let agentState = viewModel.projectAgentState(project.id)
        let sidebarTasks = viewModel.sidebarTasks(for: project)
        let isExpanded = sidebarTasks.isEmpty == false && project.sidebarCollapsed == false
        SidebarProjectButton(
            title: project.name,
            subtitle: nil,
            tooltip: project.repoPath,
            isSelected: viewModel.selectedProjectID == project.id && isOnBoard,
            terminalsActive: viewModel.selectedTaskID == "project-terminals-\(project.id)",
            terminalsOpen: viewModel.projectHasOpenTerminals(project.id),
            agentStatus: projectGlyph(project, agentState: agentState, isExpanded: isExpanded),
            onOpenTerminals: { onOpenProjectTerminals(project) },
            disclosure: sidebarTasks.isEmpty ? nil : !project.sidebarCollapsed,
            onToggleDisclosure: { viewModel.toggleSidebarCollapsed(projectID: project.id) },
            reservesDisclosureSlot: true
        ) {
            onShowProject(project)
        }
        .contextMenu {
            Button {
                onOpenProjectTerminals(project)
            } label: {
                Label("Open Terminals", systemImage: "terminal")
            }
            .accessibilityIdentifier("project-context-terminals-button")

            Button {
                onEditProject(project)
            } label: {
                Label("Edit Project", systemImage: "pencil")
            }
            .accessibilityIdentifier("project-context-edit-button")

            Divider()

            Button(role: .destructive) {
                onDeleteProject(project)
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
            .accessibilityIdentifier("project-context-delete-button")
        }
        .accessibilityIdentifier("project-filter-\(project.id)")
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(projectsSpace))
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    if dragProjectID == nil {
                        dragProjectID = project.id
                        dragStartFrame = projectFrames[project.id] ?? .zero
                    }
                    dropIndex = computeDropIndex(draggedID: project.id, translationHeight: value.translation.height)
                }
                .onEnded { _ in
                    if let target = dropIndex {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.moveProject(id: project.id, toIndex: target)
                        }
                    }
                    dragProjectID = nil
                    dropIndex = nil
                }
        )
    }

    @ViewBuilder
    private var reorderDragPreview: some View {
        if let id = dragProjectID, let project = viewModel.project(for: id) {
            SidebarProjectButton(
                title: project.name,
                subtitle: nil,
                isSelected: viewModel.selectedProjectID == id
            ) {}
                .frame(width: dragStartFrame.width)
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
                .offset(
                    x: dragStartFrame.minX + dragTranslation.width,
                    y: dragStartFrame.minY + dragTranslation.height
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var reorderInsertionLine: some View {
        if let id = dragProjectID, let dropIndex, let y = insertionLineY(dropIndex: dropIndex, draggedID: id) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(0, dragStartFrame.width - 24 * balaganUIScale), height: 2)
                .offset(x: dragStartFrame.minX + 12 * balaganUIScale, y: y - 1)
                .allowsHitTesting(false)
        }
    }

    /// Insertion index among the *other* projects, from the dragged row's current center.
    private func computeDropIndex(draggedID: Project.ID, translationHeight: CGFloat) -> Int {
        let center = dragStartFrame.midY + translationHeight
        var index = 0
        for project in viewModel.projects where project.id != draggedID {
            if let frame = projectFrames[project.id], frame.midY < center {
                index += 1
            }
        }
        return index
    }

    /// The y (in projects space) of the accent insertion line for a given drop index.
    private func insertionLineY(dropIndex: Int, draggedID: Project.ID) -> CGFloat? {
        let others = viewModel.projects
            .filter { $0.id != draggedID }
            .compactMap { projectFrames[$0.id] }
        guard others.isEmpty == false else {
            return nil
        }
        let pad = 3 * balaganUIScale
        if dropIndex <= 0 {
            return others[0].minY - pad
        }
        if dropIndex >= others.count {
            return others[others.count - 1].maxY + pad
        }
        return (others[dropIndex - 1].maxY + others[dropIndex].minY) / 2
    }
}

private struct SidebarProjectButton: View {
    let title: String
    /// A second line ("3 tasks" on All Projects). Project rows have none — their path is the tooltip.
    let subtitle: String?
    var tooltip: String? = nil
    let isSelected: Bool
    var terminalsActive: Bool = false
    var terminalsOpen: Bool = false
    /// Loudest agent state across the project's tasks (nil = nothing to say).
    var agentStatus: AgentStatusGlyph? = nil
    var onOpenTerminals: (() -> Void)? = nil
    /// nil = no task list to fold; true = expanded; false = collapsed.
    var disclosure: Bool? = nil
    var onToggleDisclosure: () -> Void = {}
    var reservesDisclosureSlot = false
    let action: () -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6 * balaganUIScale) {
            if let disclosure {
                Button(action: onToggleDisclosure) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9 * balaganUIScale, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 12 * balaganUIScale, height: 12 * balaganUIScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(disclosure ? "Hide tasks" : "Show tasks")
                .accessibilityIdentifier("project-disclosure-button")
            } else if reservesDisclosureSlot {
                // Keeps a project with no listed tasks aligned with its expandable siblings.
                Color.clear.frame(width: 12 * balaganUIScale, height: 12 * balaganUIScale)
            }
            VStack(alignment: .leading, spacing: 2 * balaganUIScale) {
                HStack(spacing: 6 * balaganUIScale) {
                    Text(title)
                        .font(.system(size: Theme.TextSize.title * balaganUIScale, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Theme.textPrimary)
                        .lineLimit(1)
                    if let agentStatus {
                        AgentStatusIndicator(glyph: agentStatus, size: Theme.TextSize.micro * balaganUIScale)
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: Theme.TextSize.small * balaganUIScale))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let onOpenTerminals {
                // "lit" (accent-tinted) when terminals are open so you can tell something's there,
                // brightest when that Terminals workspace is the selected one.
                let lit = terminalsActive || terminalsOpen
                Button(action: onOpenTerminals) {
                    Text(">_")
                        .font(.system(size: Theme.TextSize.small * balaganUIScale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(lit ? Color.accentColor : Theme.textTertiary)
                        .padding(.horizontal, 6 * balaganUIScale)
                        .padding(.vertical, 2 * balaganUIScale)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                                .fill(terminalsActive ? Color.accentColor.opacity(0.14)
                                    : (terminalsOpen ? Color.accentColor.opacity(0.10) : Theme.surfaceRaised))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                                .stroke(terminalsActive ? Color.accentColor.opacity(0.5)
                                    : (terminalsOpen ? Color.accentColor.opacity(0.35) : Theme.hairline), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(terminalsOpen ? "Show project terminals" : "Open project terminals")
                .opacity(isHovered || lit ? 1 : 0.5)
                .accessibilityIdentifier("project-terminals-button")
            }
        }
        .padding(.horizontal, 12 * balaganUIScale)
        .padding(.vertical, 8 * balaganUIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accentSoft : (isHovered ? Theme.surfaceHover : Color.clear))
        .overlay(alignment: .leading) {
            SelectionAccentBar(isSelected: isSelected, verticalInset: 5 * balaganUIScale)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .help(tooltip ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .padding(.horizontal, 8 * balaganUIScale)
    }
}

/// One task under its project in the sidebar: lane-colored dot (or the agent glyph when an agent has
/// something to say), title, and how long it has been waiting on you.
private struct SidebarTaskRow: View {
    let title: String
    let laneColor: Color
    let agentStatus: AgentStatusGlyph?
    let waitingSince: Date?
    let isSelected: Bool
    let isAsleep: Bool
    var dormantReason: String? = nil
    let action: () -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7 * balaganUIScale) {
            Group {
                if isAsleep {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9 * balaganUIScale, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .help(dormantReason ?? "Not running")
                } else if let agentStatus {
                    AgentStatusIndicator(glyph: agentStatus, size: Theme.TextSize.micro * balaganUIScale)
                } else {
                    Circle()
                        .fill(laneColor.opacity(0.8))
                        .frame(width: 6 * balaganUIScale, height: 6 * balaganUIScale)
                }
            }
            .frame(width: 12 * balaganUIScale)

            Text(title)
                .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : (isAsleep ? Theme.textTertiary : Theme.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let waitingSince {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TaskActivity.elapsed(from: waitingSince, to: context.date))
                        .font(.system(size: Theme.TextSize.micro * balaganUIScale, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.agentWaiting)
                }
            }
        }
        // Indented to sit under the project name (past the disclosure chevron).
        .padding(.leading, 30 * balaganUIScale)
        .padding(.trailing, 12 * balaganUIScale)
        .padding(.vertical, 5 * balaganUIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accentSoft : (isHovered ? Theme.surfaceHover : Color.clear))
        .overlay(alignment: .leading) {
            SelectionAccentBar(isSelected: isSelected, verticalInset: 4 * balaganUIScale)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .padding(.horizontal, 8 * balaganUIScale)
    }
}
