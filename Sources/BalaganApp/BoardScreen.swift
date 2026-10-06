import AppKit
import SwiftUI
import BalaganCore

struct BoardScreen: View {
    @ObservedObject var viewModel: BoardViewModel
    let artifactDirectory: URL?
    let terminalRuntime: TerminalRuntimeOptions
    @State private var pendingSheet: BoardSheet?
    @State private var pendingConfirmation: PendingConfirmation?

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            viewModel.isSidebarVisible.toggle()
        }
    }

    /// Live worktree state for a task (path + dirty), or nil if it has no on-disk worktree. Runs git
    /// in the view layer only, so unit tests/headless never touch real repos.
    private func worktreeInfo(for task: TaskItem) -> (repoPath: String, path: String, isDirty: Bool)? {
        guard let branch = task.branchOrWorktree?.nilIfBlank,
              let project = viewModel.project(for: task.projectID) else {
            return nil
        }
        let path = GitWorktreeManager.worktreePath(
            worktreesDirectory: project.resolvedWorktreesDirectory,
            branch: branch
        )
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return (project.repoPath, path, GitWorktreeManager.isWorktreeClean(at: path) == false)
    }

    private func makeDeleteConfirmation(for task: TaskItem) -> TaskDeleteConfirmation {
        if let info = worktreeInfo(for: task) {
            return TaskDeleteConfirmation(task: task, repoPath: info.repoPath, worktreePath: info.path, worktreeDirty: info.isDirty)
        }
        return TaskDeleteConfirmation(task: task)
    }

    private func requestWorktreeRemoval(for task: TaskItem) {
        guard let info = worktreeInfo(for: task) else {
            return
        }
        pendingConfirmation = .worktreeRemove(WorktreeRemoveConfirmation(
            taskID: task.id,
            taskTitle: task.title,
            repoPath: info.repoPath,
            worktreePath: info.path,
            isDirty: info.isDirty,
            branch: task.branchOrWorktree ?? ""
        ))
    }

    private func requestArchive(for task: TaskItem) {
        let info = worktreeInfo(for: task)
        pendingConfirmation = .archive(ArchiveConfirmation(
            taskID: task.id,
            taskTitle: task.title,
            repoPath: info?.repoPath,
            worktreePath: info?.path,
            isDirty: info?.isDirty ?? false,
            branch: task.branchOrWorktree?.nilIfBlank
        ))
    }

    var body: some View {
        HSplitView {
            if viewModel.isSidebarVisible {
                Sidebar(
                    viewModel: viewModel,
                    onCreateProject: {
                        pendingSheet = .projectForm(.create())
                    },
                    onEditProject: { project in
                        pendingSheet = .projectForm(.edit(project))
                    },
                    onDeleteProject: { project in
                        pendingConfirmation = .projectDelete(ProjectDeleteConfirmation(
                            project: project,
                            taskCount: viewModel.taskIDs(forProjectID: project.id).count
                        ))
                    },
                    onShowAllProjects: {
                        viewModel.showAllProjectTasks()
                    },
                    onShowProject: { project in
                        viewModel.showProjectTasks(projectID: project.id)
                    },
                    onShowArchived: {
                        viewModel.showArchived()
                    },
                    onOpenProjectTerminals: { project in
                        viewModel.openProjectTerminals(projectID: project.id)
                    },
                    onOpenSettings: {
                        SettingsWindowController.shared.show(viewModel: viewModel)
                    }
                )
                    .frame(width: 240 * sidebarScale)
                    // The sidebar scales independently of the main area (overrides the outer scale below).
                    .balaganUIScale(viewModel.uiAppearance.effectiveSidebarScale)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            mainContent
                .frame(minWidth: 640 * uiScale, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Main-area scale (kanban / task header / terminal) — also the base for sheets & alerts.
        .balaganUIScale(viewModel.uiAppearance.uiScale)
        .background(Color(nsColor: .windowBackgroundColor))
        // The New Task keyboard shortcut (⌘N) sets this flag on the view model; open the create form.
        .onChange(of: viewModel.pendingNewTaskRequest) { _, requested in
            guard requested else { return }
            viewModel.pendingNewTaskRequest = false
            pendingSheet = .taskForm(.create(projectID: viewModel.selectedProjectID ?? viewModel.projects.first?.id))
        }
        // The four draft-backed forms share ONE `.sheet(item:)` driven by the `BoardSheet` enum (one
        // sheet per view is the robust pattern). Settings stays on its own `.sheet(isPresented:)` above
        // — it's a bool with a launch-time env hook, not a draft, and it's also rendered offscreen by
        // AppArtifacts via its own initializer.
        .sheet(item: $pendingSheet) { sheet in
            switch sheet {
            case .projectForm(let draft):
                ProjectFormSheet(draft: draft) { savedDraft in
                    if let projectID = savedDraft.projectID {
                        viewModel.updateProject(
                            id: projectID,
                            name: savedDraft.name,
                            repoPath: savedDraft.repoPath,
                            defaultBranch: savedDraft.defaultBranch,
                            defaultAgentCommand: savedDraft.defaultAgentCommand,
                            worktreesDirectory: savedDraft.worktreesDirectory,
                            setupCommands: savedDraft.setupCommands,
                            savedPrompts: savedDraft.savedPrompts
                        )
                    } else {
                        _ = viewModel.createProject(
                            name: savedDraft.name,
                            repoPath: savedDraft.repoPath,
                            defaultBranch: savedDraft.defaultBranch,
                            defaultAgentCommand: savedDraft.defaultAgentCommand,
                            worktreesDirectory: savedDraft.worktreesDirectory,
                            setupCommands: savedDraft.setupCommands,
                            savedPrompts: savedDraft.savedPrompts
                        )
                    }
                }
            case .taskForm(let draft):
                TaskFormSheet(draft: draft, projects: viewModel.projects) { savedDraft in
                    if savedDraft.taskID == nil {
                        _ = viewModel.createTask(from: savedDraft)
                    } else {
                        viewModel.updateTask(from: savedDraft)
                    }
                }
            case .surfaceForm(let draft):
                SurfaceFormSheet(draft: draft) { savedDraft in
                    viewModel.createSurface(
                        taskID: savedDraft.taskID,
                        title: savedDraft.title,
                        cwd: savedDraft.cwd,
                        startupCommand: savedDraft.startupCommand
                    )
                }
            case .surfaceRename(let draft):
                SurfaceRenameFormSheet(draft: draft) { savedDraft in
                    viewModel.renameSurface(
                        taskID: savedDraft.taskID,
                        surfaceID: savedDraft.surfaceID,
                        title: savedDraft.title
                    )
                }
            }
        }
            // All four board confirmations share ONE alert. SwiftUI honors only one `.alert(item:)` per
            // view — stacking multiple silently suppressed all but one — so a single `PendingConfirmation`
            // enum drives the `isPresented:presenting:` form. `title`/`message` and the per-case action
            // buttons switch on the case to reproduce each alert exactly (labels, destructive/cancel
            // roles, and the project/task-delete buttons' accessibility identifiers).
            .alert(
                pendingConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }
                ),
                presenting: pendingConfirmation
            ) { confirmation in
                confirmationActions(for: confirmation)
            } message: { confirmation in
                Text(confirmation.message)
            }
        .overlay {
            if viewModel.showingCommandPalette {
                CommandPalette(commands: paletteCommands) {
                    viewModel.showingCommandPalette = false
                }
            }
        }
        // Speech playback bar: board-level so it survives switching tasks while speaking.
        .overlay(alignment: .bottom) {
            SpeechHUD(speech: SpeechController.shared)
                .padding(.bottom, 16)
        }
    }

    /// The alert buttons for whichever confirmation is pending. Each case reproduces its original
    /// buttons verbatim — labels, `.destructive`/`.cancel` roles, accessibility identifiers, and the
    /// exact teardown sequence (see `BoardViewModel.removeWorktreeAndClose`).
    @ViewBuilder
    private func confirmationActions(for confirmation: PendingConfirmation) -> some View {
        switch confirmation {
        case .projectDelete(let payload):
            Button("Delete", role: .destructive) {
                for taskID in viewModel.taskIDs(forProjectID: payload.projectID) {
                    TerminalHostRegistry.shared.closeTask(taskID: taskID)
                }
                viewModel.deleteProject(id: payload.projectID)
                pendingConfirmation = nil
            }
            .accessibilityIdentifier("project-delete-confirm-button")

            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
            .accessibilityIdentifier("project-delete-cancel-button")

        case .taskDelete(let payload):
            Button(payload.confirmLabel, role: .destructive) {
                viewModel.removeWorktreeAndClose(
                    taskID: payload.taskID,
                    repoPath: payload.repoPath,
                    worktreePath: payload.worktreePath,
                    branch: payload.branch,
                    force: payload.worktreeDirty,
                    closeSessionsFirst: false,
                    resetWorkingDirectory: false
                )
                viewModel.deleteTask(id: payload.taskID)
                pendingConfirmation = nil
            }
            .accessibilityIdentifier("task-delete-confirm-button")

            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
            .accessibilityIdentifier("task-delete-cancel-button")

        case .worktreeRemove(let payload):
            Button(payload.confirmLabel, role: .destructive) {
                viewModel.removeWorktreeAndClose(
                    taskID: payload.taskID,
                    repoPath: payload.repoPath,
                    worktreePath: payload.worktreePath,
                    branch: payload.branch,
                    force: payload.isDirty,
                    closeSessionsFirst: false,
                    resetWorkingDirectory: true
                )
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }

        case .archive(let payload):
            Button(payload.confirmLabel, role: .destructive) {
                // Close live sessions first, then remove the worktree (and repoint surfaces off it),
                // then archive. Worktree removal is force-on-dirty (the message warned).
                viewModel.removeWorktreeAndClose(
                    taskID: payload.taskID,
                    repoPath: payload.repoPath,
                    worktreePath: payload.worktreePath,
                    branch: payload.branch,
                    force: payload.isDirty,
                    closeSessionsFirst: true,
                    resetWorkingDirectory: true
                )
                viewModel.archiveTask(id: payload.taskID)
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        }
    }

    /// Commands shown in the ⌘⇧P palette. With nothing typed: recent tasks first (jump back to what
    /// you were just doing), then actions, then everything else to navigate to. Commands with a
    /// keyboard shortcut show it, so the palette also teaches them.
    private var paletteCommands: [PaletteCommand] {
        let shortcuts = viewModel.keyboardShortcuts
        func chord(_ action: ShortcutAction) -> String { shortcuts.chord(for: action).displayString }
        var commands: [PaletteCommand] = []

        // Recent tasks.
        let recent = RecentTasks.ids(
            viewModel.boardTasks.map { task in
                RecentTasks.Candidate(id: task.id, lastActiveAt: viewModel.taskLastActiveAt[task.id] ?? task.workspace.lastOpenedAt)
            },
            excluding: viewModel.selectedTaskID
        )
        for id in recent {
            guard let task = viewModel.tasks.first(where: { $0.id == id }) else { continue }
            commands.append(PaletteCommand(
                id: "recent-task-\(task.id)",
                title: task.title,
                subtitle: "Recent · \(viewModel.projectName(for: task.projectID))",
                systemImage: "clock.arrow.circlepath"
            ) { viewModel.select(task: task) })
        }

        // Actions.
        commands.append(PaletteCommand(id: "new-task", title: "New Task", systemImage: "plus", shortcut: chord(.newTask)) {
            pendingSheet = .taskForm(.create(projectID: viewModel.selectedProjectID ?? viewModel.projects.first?.id))
        })
        commands.append(PaletteCommand(id: "new-project", title: "New Project", systemImage: "folder.badge.plus") {
            pendingSheet = .projectForm(.create())
        })
        if viewModel.agentsNeedingYouCount > 0 {
            commands.append(PaletteCommand(
                id: "next-agent",
                title: "Next Agent Needing You",
                subtitle: viewModel.agentsNeedingYouCount == 1 ? "1 agent" : "\(viewModel.agentsNeedingYouCount) agents",
                systemImage: "questionmark.circle",
                shortcut: chord(.nextAgentNeedingYou)
            ) { viewModel.jumpToNextAgentNeedingYou() })
        }

        if viewModel.selectedTaskID != nil {
            commands.append(PaletteCommand(id: "show-board", title: "Show Board", systemImage: "rectangle.split.3x1", shortcut: chord(.showBoard)) {
                viewModel.showBoard()
            })
        }

        if let task = viewModel.selectedTask, task.isProjectTerminals == false {
            commands.append(PaletteCommand(id: "review-changes", title: "Review Changes", subtitle: task.title, systemImage: "plus.forwardslash.minus", shortcut: chord(.toggleChangesView)) {
                if viewModel.showingChangesView == false { viewModel.toggleChangesView() }
            })
            commands.append(PaletteCommand(id: "reader", title: "Reader Mode", subtitle: task.title, systemImage: "text.book.closed", shortcut: chord(.toggleReaderMode)) {
                if viewModel.showingReaderMode == false { viewModel.toggleReaderMode() }
            })
            commands.append(PaletteCommand(id: "new-tab", title: "New Tab", systemImage: "plus.rectangle", shortcut: chord(.newTab)) {
                viewModel.createDefaultSurface(taskID: task.id)
            })
            commands.append(PaletteCommand(id: "split-right", title: "Split Right", systemImage: "rectangle.split.2x1", shortcut: chord(.splitRight)) {
                viewModel.splitSurface(taskID: task.id, axis: .horizontal)
            })
            commands.append(PaletteCommand(id: "split-down", title: "Split Down", systemImage: "rectangle.split.1x2", shortcut: chord(.splitDown)) {
                viewModel.splitSurface(taskID: task.id, axis: .vertical)
            })
            for prompt in viewModel.savedPrompts(for: task) {
                commands.append(PaletteCommand(id: "prompt-\(prompt.id)", title: "Send: \(prompt.title)", subtitle: task.title, systemImage: "paperplane") {
                    if viewModel.sendToAgent(taskID: task.id, text: prompt.text) == false { NSSound.beep() }
                })
            }
            commands.append(PaletteCommand(id: "edit-task", title: "Edit Task", subtitle: task.title, systemImage: "pencil") {
                pendingSheet = .taskForm(.edit(task))
            })
            if viewModel.canSleepTask(taskID: task.id) {
                commands.append(PaletteCommand(id: "sleep-task", title: "Sleep Task", subtitle: task.title, systemImage: "moon.zzz") {
                    viewModel.sleepTask(taskID: task.id)
                })
            }
            commands.append(PaletteCommand(id: "archive-task", title: "Archive Task", subtitle: task.title, systemImage: "archivebox") {
                requestArchive(for: task)
            })
        }

        commands.append(PaletteCommand(
            id: "toggle-sidebar",
            title: viewModel.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            systemImage: "sidebar.leading"
        ) { toggleSidebar() })
        commands.append(PaletteCommand(id: "all-projects", title: "Show All Projects", systemImage: "square.grid.2x2") {
            viewModel.showAllProjectTasks()
        })
        commands.append(PaletteCommand(id: "show-archived", title: "Show Archived", systemImage: "archivebox") {
            viewModel.showArchived()
        })
        commands.append(PaletteCommand(id: "settings", title: "Open Settings", systemImage: "gearshape", shortcut: "⌘,") {
            SettingsWindowController.shared.show(viewModel: viewModel)
        })

        // Navigation (recent tasks already listed above aren't repeated).
        let recentSet = Set(recent)
        for task in viewModel.boardTasks where recentSet.contains(task.id) == false {
            commands.append(PaletteCommand(
                id: "go-task-\(task.id)",
                title: task.title,
                subtitle: "Task · \(viewModel.projectName(for: task.projectID))",
                systemImage: "arrow.right.circle"
            ) { viewModel.select(task: task) })
        }
        for project in viewModel.projects {
            commands.append(PaletteCommand(
                id: "go-project-\(project.id)",
                title: project.name,
                subtitle: "Project",
                systemImage: "folder"
            ) { viewModel.showProjectTasks(projectID: project.id) })
        }
        for session in viewModel.agentSessions() {
            commands.append(PaletteCommand(
                id: "go-agent-\(session.taskID)-\(session.surfaceID)",
                title: "\(session.taskTitle) · \(session.surfaceTitle)",
                subtitle: "Agent session",
                systemImage: "sparkles"
            ) { viewModel.jumpToSession(session) })
        }

        return commands
    }

    private var uiScale: CGFloat {
        CGFloat(viewModel.uiAppearance.uiScale)
    }

    private var sidebarScale: CGFloat {
        CGFloat(viewModel.uiAppearance.effectiveSidebarScale)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let task = viewModel.selectedTask {
            TaskTerminalWorkspaceScreen(
                task: task,
                viewModel: viewModel,
                onEditTask: {
                    pendingSheet = .taskForm(.edit(task))
                },
                onRestartAgent: { surfaceID in
                    TerminalRestart.restart(
                        taskID: task.id,
                        surfaceID: surfaceID,
                        viewModel: viewModel,
                        runtime: terminalRuntime,
                        artifactDirectory: artifactDirectory
                    )
                },
                onAddSurface: {
                    pendingSheet = .surfaceForm(.create(
                        task: task,
                        project: viewModel.project(for: task.projectID),
                        agentWrapperPath: viewModel.agentWrapperPath
                    ))
                },
                onRenameSurface: { surface in
                    pendingSheet = .surfaceRename(.edit(task: task, surface: surface))
                },
                onDeleteSurface: { surfaceID in
                    TerminalHostRegistry.shared.close(taskID: task.id, surfaceID: surfaceID)
                    viewModel.deleteSurface(taskID: task.id, surfaceID: surfaceID)
                },
                onNewDefaultSurface: {
                    viewModel.createDefaultSurface(taskID: task.id)
                },
                onNewAgentSurface: {
                    viewModel.createAgentSurface(taskID: task.id)
                },
                onSplitSurface: { axis in
                    viewModel.splitSurface(taskID: task.id, axis: axis)
                },
                surfaceSelection: SurfaceSelectionActions(
                    next: { viewModel.selectNextSurface(taskID: task.id) },
                    previous: { viewModel.selectPreviousSurface(taskID: task.id) },
                    atIndex: { tabIndex in viewModel.selectSurface(taskID: task.id, tabIndex: tabIndex) },
                    last: { viewModel.selectLastSurface(taskID: task.id) }
                )
            )
            .environment(\.artifactDirectory, artifactDirectory)
            .environment(\.terminalRuntime, terminalRuntime)
            .environment(\.terminalAppearance, effectiveTerminalAppearance)
        } else if viewModel.showingArchived {
            ArchivedTasksScreen(
                viewModel: viewModel,
                isSidebarHidden: !viewModel.isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                onDeleteTask: { task in
                    pendingConfirmation = .taskDelete(makeDeleteConfirmation(for: task))
                }
            )
        } else {
            KanbanBoard(
                viewModel: viewModel,
                isSidebarHidden: !viewModel.isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                onOpenSettings: {
                    SettingsWindowController.shared.show(viewModel: viewModel)
                },
                onCreateTask: {
                    pendingSheet = .taskForm(.create(projectID: viewModel.selectedProjectID ?? viewModel.projects.first?.id))
                },
                onCreateProject: {
                    pendingSheet = .projectForm(.create())
                },
                onEditTask: { task in
                    pendingSheet = .taskForm(.edit(task))
                },
                onDeleteTask: { task in
                    pendingConfirmation = .taskDelete(makeDeleteConfirmation(for: task))
                },
                onRemoveWorktree: { task in
                    requestWorktreeRemoval(for: task)
                },
                onArchiveTask: { task in
                    requestArchive(for: task)
                },
                onSleepTask: { task in
                    viewModel.sleepTask(taskID: task.id)
                }
            )
        }
    }

    private var effectiveTerminalAppearance: TerminalAppearanceSettings {
        // Terminal font size is its own pt value, adjusted only by terminal font zoom (Cmd+/Cmd–).
        // It must NOT be multiplied by the app UI scale: libghostty's runtime zoom is scale-unaware,
        // so folding uiScale in here made surfaces created at different times/scales drift in size.
        viewModel.terminalAppearance
    }
}

/// The single pending board form sheet. One enum + one `.sheet(item:)` replaces four separate
/// `.sheet(item:)` modifiers on the individual drafts. Settings is intentionally NOT here — it
/// presents via `.sheet(isPresented:)` on a launch-env-initialized bool. Each case's `id` delegates to
/// its draft so switching between forms re-presents exactly as before.
private enum BoardSheet: Identifiable {
    case projectForm(ProjectFormDraft)
    case taskForm(TaskFormDraft)
    case surfaceForm(SurfaceFormDraft)
    case surfaceRename(SurfaceRenameDraft)

    var id: String {
        switch self {
        case .projectForm(let draft): return draft.id
        case .taskForm(let draft): return draft.id
        case .surfaceForm(let draft): return draft.id
        case .surfaceRename(let draft): return draft.id
        }
    }
}

/// The single pending board confirmation. One enum + one `.alert` replaces four separate alert
/// modifiers (SwiftUI honors only one item-alert per view). Each case carries the payload struct that
/// supplies its `message`/`confirmLabel`; the enum adds the per-case `title` used by the shared alert.
private enum PendingConfirmation: Identifiable {
    case projectDelete(ProjectDeleteConfirmation)
    case taskDelete(TaskDeleteConfirmation)
    case worktreeRemove(WorktreeRemoveConfirmation)
    case archive(ArchiveConfirmation)

    var id: String {
        switch self {
        case .projectDelete(let payload): return "project-delete-\(payload.projectID)"
        case .taskDelete(let payload): return "task-delete-\(payload.taskID)"
        case .worktreeRemove(let payload): return "worktree-remove-\(payload.taskID)"
        case .archive(let payload): return "archive-\(payload.taskID)"
        }
    }

    var title: String {
        switch self {
        case .projectDelete: return "Delete Project?"
        case .taskDelete: return "Delete Task?"
        case .worktreeRemove: return "Remove Worktree?"
        case .archive: return "Archive Task?"
        }
    }

    var message: String {
        switch self {
        case .projectDelete(let payload): return payload.message
        case .taskDelete(let payload): return payload.message
        case .worktreeRemove(let payload): return payload.message
        case .archive(let payload): return payload.message
        }
    }
}

private struct ProjectDeleteConfirmation {
    let projectID: Project.ID
    let projectName: String
    let taskCount: Int

    init(project: Project, taskCount: Int) {
        self.projectID = project.id
        self.projectName = project.name
        self.taskCount = taskCount
    }

    var message: String {
        let taskLabel = taskCount == 1 ? "1 task" : "\(taskCount) tasks"
        return "This removes \"\(projectName)\", \(taskLabel), and all terminal workspaces."
    }
}

private struct TaskDeleteConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String?
    let worktreePath: String?
    let worktreeDirty: Bool
    let branch: String?

    init(task: TaskItem, repoPath: String? = nil, worktreePath: String? = nil, worktreeDirty: Bool = false) {
        self.taskID = task.id
        self.taskTitle = task.title
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.worktreeDirty = worktreeDirty
        self.branch = task.branchOrWorktree?.nilIfBlank
    }

    var hasWorktree: Bool { worktreePath != nil }
    var confirmLabel: String { worktreeDirty ? "Delete & Discard" : "Delete" }

    var message: String {
        if worktreeDirty {
            return "This removes \"\(taskTitle)\", its terminal workspace, and its git worktree — which has uncommitted changes that will be discarded. Its branch is deleted too if fully merged."
        }
        if hasWorktree {
            return "This removes \"\(taskTitle)\", its terminal workspace, and its git worktree. Its branch is deleted too if fully merged."
        }
        return "This removes \"\(taskTitle)\" and its terminal workspace."
    }
}

private struct WorktreeRemoveConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String
    let worktreePath: String
    let isDirty: Bool
    let branch: String

    var confirmLabel: String { isDirty ? "Remove & Discard" : "Remove Worktree" }

    var message: String {
        let base = "Removes the git worktree for \"\(taskTitle)\" to free space and closes its terminals. Its branch is deleted too if fully merged (kept if it has unmerged commits)."
        return isDirty ? base + " The worktree has uncommitted changes that will be discarded." : base
    }
}

private struct ArchiveConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String?
    let worktreePath: String?
    let isDirty: Bool
    let branch: String?

    var hasWorktree: Bool { worktreePath != nil }
    var confirmLabel: String { isDirty ? "Archive & Discard" : "Archive" }

    var message: String {
        var lines = [
            "\u{201C}\(taskTitle)\u{201D} will be hidden from the board and permanently deleted after \(BoardViewModel.archivedTaskRetentionDays) days. Its terminal sessions will be closed."
        ]
        if isDirty {
            lines.append("Its git worktree has uncommitted changes that will be discarded. Its branch is deleted too if fully merged (kept if it has unmerged commits).")
        } else if hasWorktree {
            lines.append("Its git worktree will be removed and its branch deleted if fully merged (kept if it has unmerged commits).")
        }
        return lines.joined(separator: "\n\n")
    }
}
