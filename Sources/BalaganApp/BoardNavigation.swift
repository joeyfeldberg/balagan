import Foundation
import BalaganCore

/// Selection and navigation for the board: project/task/archived selection, surface selection helpers,
/// and the per-project ad-hoc "Terminals" workspace. Extracted from `BoardViewModel`.
extension BoardViewModel {
    /// Opens (creating if needed) the project's ad-hoc Terminals workspace: a plain shell rooted at
    /// the repo, hidden from the board. "Many" = tabs/splits via the normal surface controls.
    func openProjectTerminals(projectID: Project.ID) {
        guard let project = project(for: projectID) else {
            return
        }
        let taskID = "project-terminals-\(projectID)"
        let workspaceID = "workspace-\(taskID)"
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            // The Terminals workspace exists; if every terminal was closed, open a fresh shell so
            // there's always something to land in.
            if tasks[index].workspace.surfaces.isEmpty {
                let surface = makeProjectTerminalShell(workspaceID: workspaceID, taskID: taskID, project: project)
                tasks[index].workspace.surfaces = [surface]
                tasks[index].workspace.layout = .tabs([.surface(surface.id)])
                tasks[index].workspace.selectedSurfaceID = surface.id
                tasks[index].workspace.lastOpenedAt = Date()
                tasks[index].updatedAt = Date()
            }
        } else {
            let surface = makeProjectTerminalShell(workspaceID: workspaceID, taskID: taskID, project: project)
            let now = Date()
            let task = TaskItem(
                id: taskID,
                projectID: projectID,
                title: "Terminals",
                workspace: Workspace(
                    id: workspaceID,
                    taskID: taskID,
                    layout: .tabs([.surface(surface.id)]),
                    selectedSurfaceID: surface.id,
                    surfaces: [surface],
                    lastOpenedAt: now
                ),
                createdAt: now,
                updatedAt: now,
                projectTerminals: true
            )
            tasks.append(task)
        }
        if let task = tasks.first(where: { $0.id == taskID }) {
            select(task: task)
        }
    }

    private func makeProjectTerminalShell(workspaceID: String, taskID: String, project: Project) -> Surface {
        var surface = Surface(
            id: "surface-\(taskID)-main",
            workspaceID: workspaceID,
            title: "shell",
            cwd: project.repoPath,
            environment: taskTerminalEnvironment(projectID: project.id, cwd: project.repoPath),
            startupCommand: nil
        )
        surface.output = [Surface.pwdPlaceholderSeed, project.repoPath]
        return surface
    }

    /// Whether a project's Terminals workspace currently has any open terminals (drives the sidebar
    /// chip highlight).
    func projectHasOpenTerminals(_ projectID: Project.ID) -> Bool {
        tasks.first { $0.id == "project-terminals-\(projectID)" }?.workspace.surfaces.isEmpty == false
    }

    func projectName(for id: Project.ID) -> String {
        projects.first { $0.id == id }?.name ?? "Unknown"
    }

    func project(for id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    func showAllProjectTasks() {
        showingArchived = false
        selectedProjectID = nil
        selectedTaskID = nil
        selectedWorkspaceID = nil
        selectedSurfaceID = nil
    }

    func showProjectTasks(projectID: Project.ID) {
        showingArchived = false
        selectedProjectID = projectID
        selectedTaskID = nil
        selectedWorkspaceID = nil
        selectedSurfaceID = nil
    }

    /// Shows the Archived view (across all projects). Mutually exclusive with a project/task selection.
    func showArchived() {
        showingArchived = true
        selectedProjectID = nil
        selectedTaskID = nil
        selectedWorkspaceID = nil
        selectedSurfaceID = nil
    }

    func select(task: TaskItem) {
        // Create the task's git worktree now, on first open, if it doesn't exist yet (task creation
        // no longer does it). Must run before the workspace mounts so the agent launches in a real dir.
        ensureWorktreeCreated(taskID: task.id)
        repairMissingWorkingDirectories(taskID: task.id)
        wakeTaskIfHibernated(taskID: task.id)
        zoomedSurfaceID = nil   // a freshly opened task shows its full workspace, not a zoomed pane
        showingArchived = false
        selectedProjectID = task.projectID
        selectedTaskID = task.id
        selectedWorkspaceID = task.workspace.id
        selectedSurfaceID = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id
        if let selectedSurfaceID {
            clearSurfaceAttention(taskID: task.id, surfaceID: selectedSurfaceID)
        }
    }

    func replacementSurfaceID(
        afterDeleting deletedSurfaceID: Surface.ID,
        previousOrderedSurfaceIDs: [Surface.ID],
        availableSurfaceIDs: [Surface.ID]
    ) -> Surface.ID? {
        guard let deletedIndex = previousOrderedSurfaceIDs.firstIndex(of: deletedSurfaceID) else {
            return availableSurfaceIDs.first
        }

        let trailingSurfaceIDs = previousOrderedSurfaceIDs.dropFirst(deletedIndex + 1)
        if let next = trailingSurfaceIDs.first(where: { availableSurfaceIDs.contains($0) }) {
            return next
        }

        let leadingSurfaceIDs = previousOrderedSurfaceIDs.prefix(deletedIndex).reversed()
        if let previous = leadingSurfaceIDs.first(where: { availableSurfaceIDs.contains($0) }) {
            return previous
        }

        return availableSurfaceIDs.first
    }

    func activeSurface(for task: TaskItem) -> Surface? {
        if let selectedSurfaceID = task.workspace.selectedSurfaceID,
           let selectedSurface = task.workspace.surfaces.first(where: { $0.id == selectedSurfaceID }) {
            return selectedSurface
        }

        return task.workspace.surfaces.first
    }

    func selectRelativeSurface(taskID: TaskItem.ID, offset: Int) {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let selectedSurfaceID = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id
        else {
            return
        }

        let nextSurfaceID = offset > 0
            ? task.workspace.surfaceID(after: selectedSurfaceID)
            : task.workspace.surfaceID(before: selectedSurfaceID)
        guard let nextSurfaceID else {
            return
        }

        select(surfaceID: nextSurfaceID, forTaskID: taskID)
    }
}
