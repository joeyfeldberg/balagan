import Foundation
import BalaganCore

/// Create / update / delete for projects and tasks, plus moving a task between status columns.
/// Extracted from `BoardViewModel`.
extension BoardViewModel {
    func createProject(
        name: String,
        repoPath: String,
        defaultBranch: String?,
        defaultAgentCommand: String?,
        worktreesDirectory: String?,
        setupCommands: String?,
        savedPrompts: [SavedPrompt] = []
    ) -> Project {
        let project = Project(
            id: uniqueID(base: name, existingIDs: Set(projects.map(\.id))),
            name: name.trimmedForStorage,
            repoPath: repoPath.trimmedForStorage,
            defaultBranch: defaultBranch?.nilIfBlank,
            defaultAgentCommand: defaultAgentCommand?.nilIfBlank,
            worktreesDirectory: worktreesDirectory?.nilIfBlank,
            setupCommands: setupCommands?.nilIfBlank,
            savedPrompts: savedPrompts.filter(\.isUsable)
        )
        projects.append(project)
        selectedProjectID = project.id
        return project
    }

    func updateProject(
        id: Project.ID,
        name: String,
        repoPath: String,
        defaultBranch: String?,
        defaultAgentCommand: String?,
        worktreesDirectory: String?,
        setupCommands: String?,
        savedPrompts: [SavedPrompt]? = nil
    ) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        projects[index].name = name.trimmedForStorage
        projects[index].repoPath = repoPath.trimmedForStorage
        projects[index].defaultBranch = defaultBranch?.nilIfBlank
        projects[index].defaultAgentCommand = defaultAgentCommand?.nilIfBlank
        projects[index].worktreesDirectory = worktreesDirectory?.nilIfBlank
        projects[index].setupCommands = setupCommands?.nilIfBlank
        if let savedPrompts {
            projects[index].savedPrompts = savedPrompts.filter(\.isUsable)
        }
    }

    /// Reorders projects: moves `id` to `targetIndex`, where `targetIndex` is the insertion position
    /// among the *other* projects (i.e. after the dragged one is removed). Order persists via autosave.
    func moveProject(id: Project.ID, toIndex targetIndex: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let project = projects.remove(at: from)
        let insertAt = max(0, min(targetIndex, projects.count))
        projects.insert(project, at: insertAt)
    }

    /// Env vars every task terminal gets, so setup commands and scripts can reference the project's
    /// main repo (`BALAGAN_REPO_PATH`) and this terminal's own directory (`BALAGAN_WORKTREE_PATH`,
    /// = the worktree when a Workspace branch is set, else the repo).
    func taskTerminalEnvironment(projectID: Project.ID, cwd: String, agentName: String? = nil) -> [String: String] {
        guard let project = project(for: projectID) else {
            return [:]
        }
        var environment = [
            "BALAGAN_REPO_PATH": project.repoPath,
            "BALAGAN_WORKTREE_PATH": cwd,
        ]
        // The agent's session name (Claude's `--name`), taken from the task title, so another agent can
        // discover it via ListAgents / cross-session messaging. The wrapper injects `--name` from this
        // on a fresh launch; it's harmless on a plain-shell surface (nothing reads it).
        if let agentName = agentName?.nilIfBlank {
            environment["BALAGAN_AGENT_NAME"] = agentName
        }
        return environment
    }

    func taskIDs(forProjectID projectID: Project.ID) -> [TaskItem.ID] {
        tasks
            .filter { $0.projectID == projectID && $0.isProjectTerminals == false }
            .map(\.id)
    }

    func deleteProject(id projectID: Project.ID) {
        guard projects.contains(where: { $0.id == projectID }) else {
            return
        }

        projects.removeAll { $0.id == projectID }
        tasks.removeAll { $0.projectID == projectID }

        if selectedProjectID == projectID {
            selectedProjectID = projects.first?.id
        }

        if let selectedTaskID,
           tasks.contains(where: { $0.id == selectedTaskID }) == false {
            self.selectedTaskID = nil
        }

        if let selectedWorkspaceID,
           tasks.contains(where: { $0.workspace.id == selectedWorkspaceID }) == false {
            self.selectedWorkspaceID = nil
        }

        if let selectedSurfaceID,
           tasks.contains(where: { $0.workspace.surfaces.contains(where: { $0.id == selectedSurfaceID }) }) == false {
            self.selectedSurfaceID = nil
        }

        if projects.isEmpty {
            selectedProjectID = nil
        }
    }

    /// - Parameters:
    ///   - selectsOnBoard: when true (the UI) the new task's project is selected and the board is
    ///     shown; false (the CLI) leaves the current view untouched — a pure background create.
    ///   - eagerWorktree: when true, the git worktree is created immediately; otherwise (the default)
    ///     it's created lazily on first open.
    func createTask(from draft: TaskFormDraft, selectsOnBoard: Bool = true, eagerWorktree: Bool = false) -> TaskItem? {
        guard let project = project(for: draft.projectID) else {
            return nil
        }

        let now = Date()
        let taskID = uniqueID(base: draft.title, existingIDs: Set(tasks.map(\.id)))
        let hasBranch = draft.branchOrWorktree.nilIfBlank != nil

        // Where the terminal runs, and whether we create the worktree now. By default we only compute
        // the path (no git) and let the first open create the worktree (`ensureWorktreeCreated`);
        // `eagerWorktree` creates it up front instead.
        let cwd: String
        let setupCommand: String?
        let worktreeUnavailable: Bool
        if eagerWorktree, hasBranch {
            let resolved = resolveWorkingDirectory(
                forProject: project,
                repoPathOverride: draft.repoPathOverride,
                branchOrWorktree: draft.branchOrWorktree
            )
            cwd = resolved.cwd
            setupCommand = resolved.createdWorktree ? project.setupCommands?.nilIfBlank : nil
            worktreeUnavailable = resolved.worktreeUnavailable
        } else {
            cwd = plannedWorkingDirectory(
                forProject: project,
                repoPathOverride: draft.repoPathOverride,
                branchOrWorktree: draft.branchOrWorktree
            )
            // Setup runs once, in the worktree, when it's first created on open.
            setupCommand = hasBranch ? project.setupCommands?.nilIfBlank : nil
            worktreeUnavailable = false
        }
        let surfaceID = "surface-\(taskID)-main"
        let agentCommand = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: project.defaultAgentCommand,
            wrapperPath: agentWrapperPath
        )
        // If an isolated worktree was requested but couldn't be created (eager path), don't auto-launch
        // the agent in the project's main checkout.
        let startupCommand = worktreeUnavailable ? nil : agentCommand?.nilIfBlank
        let mainSurface = makeMainSurface(
            surfaceID: surfaceID,
            taskID: taskID,
            projectID: project.id,
            agentName: draft.title.trimmedForStorage,
            cwd: cwd,
            startupCommand: startupCommand,
            setupCommand: setupCommand,
            worktreeUnavailable: worktreeUnavailable,
            branch: draft.branchOrWorktree
        )
        let task = TaskItem(
            id: taskID,
            projectID: project.id,
            title: draft.title.trimmedForStorage,
            notes: draft.summary.trimmedForStorage,
            status: draft.status,
            priority: draft.priority,
            tags: draft.normalizedTags,
            repoPathOverride: draft.repoPathOverride.nilIfBlank,
            branchOrWorktree: draft.branchOrWorktree.nilIfBlank,
            workspace: Workspace(
                id: "workspace-\(taskID)",
                taskID: taskID,
                layout: .tabs([.surface(surfaceID)]),
                selectedSurfaceID: surfaceID,
                surfaces: [mainSurface],
                lastOpenedAt: now
            ),
            createdAt: now,
            updatedAt: now
        )

        tasks.append(task)
        // The CLI creates in the background (selectsOnBoard: false) — don't yank the user's current
        // view to the board. The UI form selects the project + shows the board so the new task appears.
        if selectsOnBoard {
            selectedProjectID = project.id
            selectedTaskID = nil
        }
        return task
    }

    /// Builds a task's main "agent" surface, seeding its scrollback with either a plain `$ pwd`
    /// banner or the worktree-unavailable warning when the requested worktree couldn't be created.
    private func makeMainSurface(
        surfaceID: Surface.ID,
        taskID: TaskItem.ID,
        projectID: Project.ID,
        agentName: String,
        cwd: String,
        startupCommand: String?,
        setupCommand: String?,
        worktreeUnavailable: Bool,
        branch: String
    ) -> Surface {
        var mainSurface = Surface(
            id: surfaceID,
            workspaceID: "workspace-\(taskID)",
            title: "agent",
            cwd: cwd,
            environment: taskTerminalEnvironment(projectID: projectID, cwd: cwd, agentName: agentName),
            startupCommand: startupCommand,
            setupCommand: setupCommand,
            agentLaunchMetadata: agentLaunchMetadata(
                startupCommand: startupCommand,
                cwd: cwd
            )
        )
        if worktreeUnavailable {
            mainSurface.output = worktreeUnavailableBanner(branch: branch, cwd: cwd)
        } else {
            mainSurface.output = [Surface.pwdPlaceholderSeed, cwd]
        }
        return mainSurface
    }

    func worktreeUnavailableBanner(branch: String, cwd: String) -> [String] {
        [
            "⚠️  Could not create a git worktree for “\(branch.nilIfBlank ?? "")”.",
            "    This terminal is the project's MAIN checkout — the agent was not started.",
            "    Check the branch/base, then reopen the task to retry.",
            Surface.pwdPlaceholderSeed,
            cwd,
        ]
    }

    func updateTask(from draft: TaskFormDraft) {
        guard let taskID = draft.taskID,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              projects.contains(where: { $0.id == draft.projectID })
        else {
            return
        }

        // Where the task's terminals were headed before the edit, so a workspace change can move them.
        let previousDirectory = project(for: tasks[index].projectID).map {
            plannedWorkingDirectory(
                forProject: $0,
                repoPathOverride: tasks[index].repoPathOverride,
                branchOrWorktree: tasks[index].branchOrWorktree
            )
        }

        tasks[index].projectID = draft.projectID
        tasks[index].title = draft.title.trimmedForStorage
        tasks[index].notes = draft.summary.trimmedForStorage
        tasks[index].status = draft.status
        tasks[index].priority = draft.priority
        tasks[index].tags = draft.normalizedTags
        tasks[index].repoPathOverride = draft.repoPathOverride.nilIfBlank
        tasks[index].branchOrWorktree = draft.branchOrWorktree.nilIfBlank
        tasks[index].updatedAt = Date()
        if let previousDirectory {
            retargetWorkingDirectory(taskIndex: index, from: previousDirectory)
        }
        selectedProjectID = draft.projectID
        if selectedTaskID != nil {
            selectedTaskID = taskID
        }
    }

    func deleteTask(id taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        let removedTask = tasks.remove(at: index)
        if selectedTaskID == removedTask.id {
            selectedTaskID = nil
        }
        if selectedProjectID == removedTask.projectID,
           tasks.contains(where: { $0.projectID == removedTask.projectID }) == false {
            selectedProjectID = nil
        }
    }

    func move(task: TaskItem, to status: TaskStatus) {
        move(taskID: task.id, to: status, at: Date())
    }

    func move(taskID: TaskItem.ID, to status: TaskStatus) {
        move(taskID: taskID, to: status, at: Date())
    }

    private func move(taskID: TaskItem.ID, to status: TaskStatus, at date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        tasks[index].status = status
        tasks[index].updatedAt = date
    }
}
