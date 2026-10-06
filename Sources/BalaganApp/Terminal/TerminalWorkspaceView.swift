import AppKit
import SwiftUI
import BalaganCore

struct TaskTerminalWorkspaceScreen: View {
    let task: TaskItem
    @ObservedObject var viewModel: BoardViewModel
    let onEditTask: () -> Void
    /// Restart the agent in a tab (nil = the selected tab).
    var onRestartAgent: (Surface.ID?) -> Void = { _ in }
    let onAddSurface: () -> Void
    let onRenameSurface: (Surface) -> Void
    let onDeleteSurface: (Surface.ID) -> Void
    let onNewDefaultSurface: () -> Void
    let onNewAgentSurface: () -> Void
    let onSplitSurface: (SplitAxis) -> Void
    let surfaceSelection: SurfaceSelectionActions

    private func taskWorktreeDirectory() -> String? {
        viewModel.taskWorkingDirectory(task)
    }

    /// Opens the task's worktree in Zed (as a project).
    private func openTaskInZed() {
        guard let directory = taskWorktreeDirectory() else { return }
        EditorLauncher.openInZed(path: directory)
    }

    /// Opens the task's worktree in Fork (as a git repository).
    private func openTaskInFork() {
        guard let directory = taskWorktreeDirectory() else { return }
        EditorLauncher.openInFork(path: directory)
    }

    private var activeSurfaceID: Surface.ID {
        task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id ?? ""
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TerminalWorkspace(
                task: task,
                projectName: viewModel.projectName(for: task.projectID),
                workspace: task.workspace,
                zoomedSurfaceID: $viewModel.zoomedSurfaceID,
                // Project Terminals: no status/edit affordances (it isn't a kanban task).
                status: task.isProjectTerminals ? nil : task.status,
                onMoveTask: task.isProjectTerminals ? nil : { status in
                    viewModel.move(task: task, to: status)
                },
                onEditTask: task.isProjectTerminals ? nil : onEditTask,
                onRestartAgent: task.isProjectTerminals ? nil : onRestartAgent,
                onAddSurface: onAddSurface,
                onNewDefaultSurface: onNewDefaultSurface,
                onNewAgentSurface: (task.isProjectTerminals || viewModel.project(for: task.projectID)?.defaultAgentCommand?.nilIfBlank == nil) ? nil : onNewAgentSurface,
                onSplitSurface: onSplitSurface,
                surfaceSelection: surfaceSelection,
                onEndedProcessSurface: { taskID, surfaceID in
                    // Only a plain shell's tab closes when its process exits. An agent tab keeps its
                    // session: it's resumed right away (quit-after-update) or offers Resume.
                    if viewModel.handleEndedProcess(taskID: taskID, surfaceID: surfaceID) == .closeTab {
                        TerminalHostRegistry.shared.close(taskID: taskID, surfaceID: surfaceID)
                        viewModel.deleteSurface(taskID: taskID, surfaceID: surfaceID)
                    }
                },
                fontZoom: FontZoomActions(
                    increase: { evidenceName in
                        let fontSize = viewModel.increaseTerminalFontSize()
                        TerminalHostRegistry.shared.performSharedFontZoomShortcut(
                            action: "increase_font_size:1",
                            evidenceName: evidenceName,
                            appFontSize: fontSize
                        )
                    },
                    decrease: { evidenceName in
                        let fontSize = viewModel.decreaseTerminalFontSize()
                        TerminalHostRegistry.shared.performSharedFontZoomShortcut(
                            action: "decrease_font_size:1",
                            evidenceName: evidenceName,
                            appFontSize: fontSize
                        )
                    },
                    reset: { evidenceName in
                        let fontSize = viewModel.resetTerminalFontSize()
                        TerminalHostRegistry.shared.performSharedFontZoomShortcut(
                            action: "reset_font_size",
                            evidenceName: evidenceName,
                            appFontSize: fontSize
                        )
                    }
                ),
                onSelectSurface: { surfaceID in
                    viewModel.select(surfaceID: surfaceID, forTaskID: task.id)
                },
                onRenameSurface: onRenameSurface,
                onDeleteSurface: onDeleteSurface,
                onMoveSurfaceTab: { from, to in
                    viewModel.moveSurfaceTab(taskID: task.id, fromOffset: from, toOffset: to)
                },
                workingDirectory: taskWorktreeDirectory(),
                devServerPorts: viewModel.devServerPorts[task.id] ?? [],
                savedPrompts: viewModel.savedPrompts(for: task),
                promptBlocker: viewModel.agentSendBlocker(taskID: task.id),
                onSendPrompt: { prompt in
                    if viewModel.sendToAgent(taskID: task.id, text: prompt.text) == false { NSSound.beep() }
                },
                onOpenInZed: EditorLauncher.isZedInstalled ? { openTaskInZed() } : nil,
                onOpenInFork: EditorLauncher.isForkInstalled ? { openTaskInFork() } : nil,
                tracksPullRequest: viewModel.tracksPullRequest(task),
                pullRequest: viewModel.pullRequests[task.id],
                isRefreshingPullRequest: viewModel.pullRequestsRefreshing.contains(task.id),
                pullRequestUnavailableReason: viewModel.pullRequestsUnavailableReason,
                onRefreshPullRequest: { viewModel.refreshPullRequest(taskID: task.id) },
                attentionSurfaceIDs: Set(
                    task.workspace.surfaces
                        .filter { viewModel.surfaceNeedsAttention(taskID: task.id, surfaceID: $0.id) }
                        .map(\.id)
                ),
                waitingSurfaceIDs: Set(
                    task.workspace.surfaces
                        .filter { viewModel.surfaceIsWaiting(taskID: task.id, surfaceID: $0.id) }
                        .map(\.id)
                ),
                isReaderModeActive: viewModel.showingReaderMode,
                readerFontSize: viewModel.readerFontSize,
                readerTheme: viewModel.readerTheme,
                readerSourceProvider: { surface in viewModel.readerTranscriptSource(for: surface) },
                onToggleReaderMode: { viewModel.toggleReaderMode() },
                onAdjustReaderFontSize: { delta in viewModel.adjustReaderFontSize(by: delta) },
                onSelectReaderTheme: { theme in viewModel.setReaderTheme(theme) },
                isChangesViewActive: viewModel.showingChangesView,
                changesPane: viewModel.showingChangesView
                    ? AnyView(ChangesPane(task: task, viewModel: viewModel))
                    : nil,
                onToggleChangesView: { viewModel.toggleChangesView() },
                endedAgent: viewModel.endedAgent(taskID: task.id, surfaceID: activeSurfaceID),
                autoResumeNotice: viewModel.agentAutoResumeNotice.flatMap { notice in
                    notice.key == viewModel.hostKey(task.id, activeSurfaceID) ? notice.text : nil
                },
                onResumeEndedAgent: { surfaceID in viewModel.resumeEndedAgent(taskID: task.id, surfaceID: surfaceID) },
                onCloseEndedAgent: { surfaceID in
                    viewModel.dismissEndedAgent(taskID: task.id, surfaceID: surfaceID)
                    TerminalHostRegistry.shared.close(taskID: task.id, surfaceID: surfaceID)
                    viewModel.deleteSurface(taskID: task.id, surfaceID: surfaceID)
                },
                agentChoices: task.isProjectTerminals ? [] : viewModel.offeredAgentProfiles.map { profile in
                    AgentChoice(
                        id: profile.id,
                        name: profile.displayName,
                        isProjectDefault: AgentKind.inCommand(viewModel.project(for: task.projectID)?.defaultAgentCommand)?.rawValue == profile.id
                    )
                },
                onNewAgentOfKind: { profileID in viewModel.createAgentSurface(taskID: task.id, profileID: profileID) },
            )
            .onAppear {
                if viewModel.tracksPullRequest(task) {
                    viewModel.refreshPullRequest(taskID: task.id)
                }
            }

            Text("terminal workspace")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("task-terminal-workspace")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TerminalWorkspace: View {
    let task: TaskItem
    var projectName: String? = nil
    let workspace: Workspace
    /// Bound to `BoardViewModel.zoomedSurfaceID` so the Zoom Pane menu shortcut can toggle it too.
    @Binding var zoomedSurfaceID: Surface.ID?
    var status: TaskStatus? = nil
    var onMoveTask: ((TaskStatus) -> Void)? = nil
    var onEditTask: (() -> Void)? = nil
    var onRestartAgent: ((Surface.ID) -> Void)? = nil
    let onAddSurface: () -> Void
    var onNewDefaultSurface: () -> Void = {}
    var onNewAgentSurface: (() -> Void)?
    var onSplitSurface: (SplitAxis) -> Void = { _ in }
    var surfaceSelection = SurfaceSelectionActions()
    var onEndedProcessSurface: (TaskItem.ID, Surface.ID) -> Void = { _, _ in }
    var fontZoom = FontZoomActions()
    let onSelectSurface: (Surface.ID) -> Void
    let onRenameSurface: (Surface) -> Void
    let onDeleteSurface: (Surface.ID) -> Void
    var onMoveSurfaceTab: (Int, Int) -> Void = { _, _ in }
    /// The task's checkout on disk, for "Open in → Finder" and "Copy Path".
    var workingDirectory: String? = nil
    /// Local servers this task's terminals started.
    var devServerPorts: [DevServerPort] = []
    /// Saved prompts for the ⋯ menu's Send Prompt, and why sending isn't possible right now.
    var savedPrompts: [SavedPrompt] = []
    var promptBlocker: String? = nil
    var onSendPrompt: (SavedPrompt) -> Void = { _ in }
    var onOpenInZed: (() -> Void)?
    var onOpenInFork: (() -> Void)?
    var tracksPullRequest = false
    var pullRequest: TaskPullRequest? = nil
    var isRefreshingPullRequest = false
    var pullRequestUnavailableReason: String? = nil
    var onRefreshPullRequest: () -> Void = {}
    var attentionSurfaceIDs: Set<Surface.ID> = []
    var waitingSurfaceIDs: Set<Surface.ID> = []
    var isReaderModeActive = false
    var readerFontSize: Double = UIAppearanceSettings.defaultReaderFontSize
    var readerTheme: ReaderTheme = .dark
    var readerSourceProvider: (Surface) -> ReaderTranscriptSource? = { _ in nil }
    var onToggleReaderMode: (() -> Void)?
    var onAdjustReaderFontSize: (Double) -> Void = { _ in }
    var onSelectReaderTheme: (ReaderTheme) -> Void = { _ in }
    var isChangesViewActive = false
    /// The Changes pane, built by the screen (it needs the view model); nil when not showing.
    var changesPane: AnyView? = nil
    var onToggleChangesView: (() -> Void)?
    /// The active tab's agent exited and is waiting on you (Resume / Close).
    var endedAgent: EndedAgent? = nil
    /// "Resumed after it exited" note for the active tab.
    var autoResumeNotice: String? = nil
    var onResumeEndedAgent: (Surface.ID) -> Void = { _ in }
    var onCloseEndedAgent: (Surface.ID) -> Void = { _ in }
    /// The agents `+` offers ("New Codex Tab", "New pi Tab", …).
    var agentChoices: [AgentChoice] = []
    var onNewAgentOfKind: (String) -> Void = { _ in }
    @Environment(\.balaganUIScale) private var balaganUIScale

    /// The left "breadcrumb": status dot + project / task title. Opens a menu to change status / edit
    /// the task (the only place that metadata lives now that the header is a single tab-forward bar).
    private func taskBreadcrumb(status: TaskStatus?) -> some View {
        let hasMenu = (status != nil && onMoveTask != nil) || onEditTask != nil
        let label = breadcrumbText(showsChevron: hasMenu)
            .lineLimit(1)
            .accessibilityIdentifier("task-detail-title")

        return Group {
            if hasMenu {
            Menu {
                if let status, let onMoveTask {
                    Picker("Status", selection: Binding(get: { status }, set: { onMoveTask($0) })) {
                        ForEach(TaskStatus.defaults) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("task-status-control")
                }
                if let onEditTask {
                    Divider()
                    Button {
                        onEditTask()
                    } label: {
                        Label("Edit Task…", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("edit-task-button")
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Task status and settings")
            } else {
                label
            }
        }
    }

    /// The breadcrumb as a single concatenated Text. A `borderlessButton` Menu label keeps only Text
    /// (dropping Circle/Image views), so the status dot and disclosure chevron are inline SF Symbols.
    private func breadcrumbText(showsChevron: Bool) -> Text {
        var text = Text("")
        if let projectName {
            text = text
                + Text("\(projectName) / ")
                    .font(.system(size: Theme.TextSize.title * balaganUIScale))
                    .foregroundColor(Theme.textTertiary)
        }
        text = text
            + Text(task.title)
                .font(.system(size: Theme.TextSize.title * balaganUIScale, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
        if showsChevron {
            text = text
                + Text("  ")
                + Text(Image(systemName: "chevron.down"))
                    .font(.system(size: 9 * balaganUIScale, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activeSurface {
                headerBar(activeSurface: activeSurface)

                // Reader mode swaps the pane, not overlays it: the terminal host survives detachment
                // (it's the same registry-cached NSView an unselected tab has), the header/tab strip
                // stays usable, and keyboard focus cleanly leaves the terminal.
                if let changesPane {
                    changesPane
                } else if isReaderModeActive, let onToggleReaderMode {
                    ReaderModeView(
                        source: readerSourceProvider(activeSurface),
                        fallbackText: activeSurface.scrollbackSnapshot,
                        fontSize: readerFontSize,
                        theme: readerTheme,
                        onAdjustFontSize: onAdjustReaderFontSize,
                        onSelectTheme: onSelectReaderTheme,
                        onDismiss: onToggleReaderMode
                    )
                } else {
                    TerminalLayoutView(
                        taskID: task.id,
                        workspace: workspace,
                        activeSurface: activeSurface,
                        zoomedSurfaceID: zoomedSurfaceID,
                        onSelectSurface: onSelectSurface,
                        onEndedProcessSurface: onEndedProcessSurface,
                        shortcuts: makeShortcutContext(activeSurface: activeSurface)
                    )
                    .overlay(alignment: .bottom) {
                        if let endedAgent {
                            AgentExitedCard(
                                ended: endedAgent,
                                scale: balaganUIScale,
                                onResume: { onResumeEndedAgent(activeSurface.id) },
                                onClose: { onCloseEndedAgent(activeSurface.id) }
                            )
                        }
                    }
                    .overlay(alignment: .top) {
                        if let autoResumeNotice {
                            AutoResumeNotice(text: autoResumeNotice, scale: balaganUIScale)
                                .padding(.top, 10 * balaganUIScale)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: autoResumeNotice)
                }
            } else {
                EmptyTerminalWorkspace(task: task, onAddSurface: onNewDefaultSurface)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Single tab-forward header bar: a task breadcrumb (status + project / title) on the
    /// left, the terminal tabs as the focus, and a minimal split + overflow cluster on the
    /// right. Status & "edit task" live in the breadcrumb menu; rename / delete / new-agent /
    /// configured-tab live in the ⋯ overflow.
    private func headerBar(activeSurface: Surface) -> some View {
        HStack(spacing: 8 * balaganUIScale) {
            taskBreadcrumb(status: status)

            Divider()
                .frame(height: 18 * balaganUIScale)

            if workspace.tabSurfaces.isEmpty == false {
                WorkspaceTabStrip(
                    surfaces: workspace.tabSurfaces,
                    selectedID: workspace.currentTabRepresentativeSurfaceID ?? activeSurface.id,
                    attentionIDs: attentionSurfaceIDs,
                    waitingIDs: waitingSurfaceIDs,
                    scale: balaganUIScale,
                    onSelect: onSelectSurface,
                    onMove: onMoveSurfaceTab,
                    onClose: onDeleteSurface,
                    onRename: onRenameSurface,
                    onRestartAgent: onRestartAgent
                )
            }

            Button {
                onNewDefaultSurface()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .help("New terminal tab (right-click for an agent tab)")
            .accessibilityIdentifier("create-terminal-tab-button")
            .contextMenu {
                Button {
                    onNewDefaultSurface()
                } label: {
                    Label("New Terminal Tab", systemImage: "terminal")
                }
                if agentChoices.isEmpty == false {
                    Divider()
                    ForEach(agentChoices) { choice in
                        Button {
                            onNewAgentOfKind(choice.id)
                        } label: {
                            Label(
                                choice.isProjectDefault ? "New \(choice.name) Tab (project default)" : "New \(choice.name) Tab",
                                systemImage: "sparkles"
                            )
                        }
                        .accessibilityIdentifier("new-agent-tab-\(choice.id)")
                    }
                }
            }
            .keyboardShortcut("t", modifiers: [.command])

            Spacer(minLength: 8 * balaganUIScale)

            if onToggleReaderMode != nil || onToggleChangesView != nil {
                WorkspaceViewSwitcher(
                    selection: activeView,
                    showsReader: onToggleReaderMode != nil,
                    showsChanges: onToggleChangesView != nil,
                    scale: balaganUIScale,
                    onSelect: selectView
                )
            }

            if tracksPullRequest {
                PullRequestHeaderButton(
                    pullRequest: pullRequest,
                    isRefreshing: isRefreshingPullRequest,
                    unavailableReason: pullRequestUnavailableReason,
                    onRefresh: onRefreshPullRequest,
                    scale: balaganUIScale
                )
            }

            if devServerPorts.isEmpty == false {
                DevServerChips(ports: devServerPorts)
            }

            openInMenu

            overflowMenu(activeSurface: activeSurface)
        }
        .padding(.horizontal, 10 * balaganUIScale)
        .padding(.vertical, 7 * balaganUIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    /// Which of the task's three views is showing.
    private var activeView: WorkspaceView {
        if isChangesViewActive { return .changes }
        if isReaderModeActive { return .reader }
        return .terminal
    }

    /// Switches views through the existing toggles (each is exclusive with the other, so at most one
    /// toggle runs; choosing the current view does nothing).
    private func selectView(_ view: WorkspaceView) {
        guard view != activeView else { return }
        switch view {
        case .terminal:
            if isChangesViewActive { onToggleChangesView?() }
            if isReaderModeActive { onToggleReaderMode?() }
        case .reader:
            onToggleReaderMode?()
        case .changes:
            onToggleChangesView?()
        }
    }

    /// One menu for leaving Balagan with this task's checkout: editor, git client, Finder, or the path.
    private var openInMenu: some View {
        Menu {
            if let onOpenInZed {
                Button {
                    onOpenInZed()
                } label: {
                    Label("Zed", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityIdentifier("open-in-zed-button")
            }
            if let onOpenInFork {
                Button {
                    onOpenInFork()
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                .accessibilityIdentifier("open-in-fork-button")
            }
            if let workingDirectory {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workingDirectory)])
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .accessibilityIdentifier("open-in-finder-button")
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workingDirectory, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copy-worktree-path-button")
            }
        } label: {
            HStack(spacing: 4 * balaganUIScale) {
                Image(systemName: "arrow.up.forward.app")
                Text("Open in")
            }
            .font(.system(size: Theme.TextSize.body * balaganUIScale, weight: .medium))
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help(workingDirectory.map { "Open \($0)" } ?? "Open this task's checkout")
        .accessibilityIdentifier("open-in-menu")
    }

    /// The ⋯ overflow: layout (split / zoom), new-agent / configured tab, and rename / delete for the
    /// active tab. Split and zoom live here now that the header shows views, not layout; their
    /// shortcuts (⌘D, ⇧⌘D, ⇧⌘⏎) come from the Terminal menu, so the menu shows them too.
    private func overflowMenu(activeSurface: Surface) -> some View {
        Menu {
            SendPromptMenu(prompts: savedPrompts, blocker: promptBlocker, onSend: onSendPrompt)
            Divider()
            Button {
                onSplitSurface(.horizontal)
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .accessibilityIdentifier("split-terminal-right-button")
            Button {
                onSplitSurface(.vertical)
            } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .accessibilityIdentifier("split-terminal-down-button")
            Button {
                zoomedSurfaceID = zoomedSurfaceID == activeSurface.id ? nil : activeSurface.id
            } label: {
                Label(zoomedSurfaceID == activeSurface.id ? "Unzoom Pane" : "Zoom Pane",
                      systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("zoom-pane-button")
            Divider()
            if let onNewAgentSurface {
                Button {
                    onNewAgentSurface()
                } label: {
                    Label("New Agent Tab", systemImage: "terminal.fill")
                }
                .accessibilityIdentifier("create-agent-terminal-tab-button")
            }
            Button {
                onAddSurface()
            } label: {
                Label("New Configured Tab…", systemImage: "plus.square.on.square")
            }
            .accessibilityIdentifier("configure-terminal-tab-button")
            Divider()
            Button {
                onRenameSurface(activeSurface)
            } label: {
                Label("Rename Tab…", systemImage: "pencil")
            }
            .accessibilityIdentifier("rename-terminal-tab-button")
            Button(role: .destructive) {
                onDeleteSurface(activeSurface.id)
            } label: {
                Label("Delete Tab", systemImage: "trash")
            }
            .accessibilityIdentifier("delete-terminal-tab-button")
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: Theme.TextSize.title * balaganUIScale))
        .help("More terminal actions")
        .accessibilityIdentifier("terminal-overflow-menu")
    }

    private func makeShortcutContext(activeSurface: Surface) -> TerminalShortcutContext {
        TerminalShortcutContext(
            newTab: onNewDefaultSurface,
            closeCurrent: {
                onDeleteSurface(activeSurface.id)
                if zoomedSurfaceID == activeSurface.id {
                    zoomedSurfaceID = nil
                }
            },
            nextTab: surfaceSelection.next,
            previousTab: surfaceSelection.previous,
            selectTab: surfaceSelection.atIndex,
            selectLastTab: surfaceSelection.last,
            splitRight: {
                zoomedSurfaceID = nil
                onSplitSurface(.horizontal)
            },
            splitDown: {
                zoomedSurfaceID = nil
                onSplitSurface(.vertical)
            },
            nextSplit: surfaceSelection.next,
            previousSplit: surfaceSelection.previous,
            focusSplit: { direction in
                guard let current = workspace.selectedSurfaceID ?? workspace.surfaces.first?.id,
                      let neighbor = workspace.neighborSurface(of: current, direction: direction)
                else {
                    return
                }
                onSelectSurface(neighbor)
            },
            toggleZoom: {
                zoomedSurfaceID = zoomedSurfaceID == activeSurface.id ? nil : activeSurface.id
            },
            increaseFontSize: fontZoom.increase,
            decreaseFontSize: fontZoom.decrease,
            resetFontSize: fontZoom.reset
        )
    }

    private var activeSurface: Surface? {
        if let selectedSurfaceID = workspace.selectedSurfaceID,
           let selectedSurface = workspace.surfaces.first(where: { $0.id == selectedSurfaceID }) {
            return selectedSurface
        }

        return workspace.surfaces.first
    }
}

/// The task's three views of the same work.
enum WorkspaceView: CaseIterable {
    case terminal, reader, changes

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .reader: return "Reader"
        case .changes: return "Changes"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .reader: return "text.book.closed"
        case .changes: return "plus.forwardslash.minus"
        }
    }

    var shortcutHint: String {
        switch self {
        case .terminal: return "Esc from Reader or Changes"
        case .reader: return "⇧⌘R"
        case .changes: return "⇧⌘G"
        }
    }
}

/// "Terminal | Reader | Changes" — a compact segmented switch in the header's own style (the stock
/// segmented Picker doesn't follow the UI scale and reads heavier than the rest of the bar).
private struct WorkspaceViewSwitcher: View {
    let selection: WorkspaceView
    let showsReader: Bool
    let showsChanges: Bool
    let scale: CGFloat
    let onSelect: (WorkspaceView) -> Void

    private var views: [WorkspaceView] {
        WorkspaceView.allCases.filter { view in
            switch view {
            case .terminal: return true
            case .reader: return showsReader
            case .changes: return showsChanges
            }
        }
    }

    var body: some View {
        // Labels when they fit; icon-only segments (names in the tooltips) when the header is tight,
        // e.g. on a narrow window. Never wrap a label.
        ViewThatFits(in: .horizontal) {
            segments(showsLabels: true)
            segments(showsLabels: false)
        }
        .layoutPriority(1)
    }

    private func segments(showsLabels: Bool) -> some View {
        HStack(spacing: 2 * scale) {
            ForEach(views, id: \.self) { view in
                segment(view, showsLabel: showsLabels)
            }
        }
        .fixedSize()
        .padding(2 * scale)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .fill(Theme.bgWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-view-switcher")
    }

    private func segment(_ view: WorkspaceView, showsLabel: Bool) -> some View {
        let isSelected = view == selection
        return Button {
            onSelect(view)
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: view.symbol)
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                if showsLabel {
                    Text(view.title)
                        .font(.system(size: Theme.TextSize.body * scale, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 9 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton - 1, style: .continuous)
                    .fill(isSelected ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(view.title) (\(view.shortcutHint))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace-view-\(view.title.lowercased())")
    }
}

/// Along the bottom of an agent tab whose process exited: what happened and the one obvious next
/// step, with the terminal's last output still readable above it. ⏎ also resumes — the terminal host
/// forwards it (see `exitedSurfaceReturnReporter`).
private struct AgentExitedCard: View {
    let ended: EndedAgent
    let scale: CGFloat
    let onResume: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12 * scale) {
            Image(systemName: ended.offer == .resume ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                .font(.system(size: 22 * scale))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("\(ended.agentName) exited")
                    .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: Theme.TextSize.small * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12 * scale)
            Button("Close Tab", action: onClose)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ended-agent-close-button")
            Button(ended.offer == .resume ? "Resume  ⏎" : "Start Agent  ⏎", action: onResume)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ended-agent-resume-button")
        }
        .font(.system(size: Theme.TextSize.body * scale))
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 12 * scale)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .padding(12 * scale)
        .accessibilityIdentifier("ended-agent-card")
    }

    private var detail: String {
        switch ended.offer {
        case .resume where ended.gaveUpAutoResume:
            return "It exited again right after resuming, so Balagan stopped retrying. The session is saved; resume when it's ready."
        case .resume:
            return "Its session is saved. Resume picks the conversation up where it left off."
        case .restart:
            return "No session was captured for this tab, so it starts fresh."
        }
    }
}

/// "Codex exited right after starting — probably updating itself — so its session was resumed."
private struct AutoResumeNotice: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 7 * scale) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(Theme.accent)
            Text(text)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().stroke(Theme.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(maxWidth: 520 * scale)
        .accessibilityIdentifier("auto-resume-notice")
    }
}

/// One agent the `+` menu can open a tab for.
struct AgentChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let isProjectDefault: Bool
}
