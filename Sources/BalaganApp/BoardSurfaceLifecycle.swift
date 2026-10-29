import Foundation
import BalaganCore

/// Terminal-surface lifecycle: tab selection, creation (shell / agent / split), rename, delete,
/// and live state updates. Extracted from `BoardViewModel`; the shared helpers it relies on
/// (`activeSurface`, `replacementSurfaceID`, `selectRelativeSurface`, `agentLaunchMetadata`) remain
/// on the view model.
extension BoardViewModel {
    func setSplitWeights(taskID: TaskItem.ID, key: String, weights: [Double]) {
        guard let index = taskIndex(for: taskID) else {
            return
        }
        tasks[index].workspace.setSplitWeights(weights, forKey: key)
        tasks[index].updatedAt = Date()
    }

    func equalizeSplits(taskID: TaskItem.ID) {
        guard let index = taskIndex(for: taskID) else {
            return
        }
        tasks[index].workspace.equalizeSplits()
        tasks[index].updatedAt = Date()
    }

    func select(surfaceID: Surface.ID, forTaskID taskID: TaskItem.ID) {
        guard let index = taskIndex(for: taskID) else {
            return
        }

        guard tasks[index].workspace.surfaces.contains(where: { $0.id == surfaceID }) else {
            return
        }

        tasks[index].workspace.selectedSurfaceID = surfaceID
        tasks[index].touchWorkspace()
        if selectedTaskID == taskID {
            selectedWorkspaceID = tasks[index].workspace.id
            selectedSurfaceID = surfaceID
        }
        clearSurfaceAttention(taskID: taskID, surfaceID: surfaceID)
    }

    func selectNextSurface(taskID: TaskItem.ID) {
        selectRelativeSurface(taskID: taskID, offset: 1)
    }

    func selectPreviousSurface(taskID: TaskItem.ID) {
        selectRelativeSurface(taskID: taskID, offset: -1)
    }

    func selectSurface(taskID: TaskItem.ID, tabIndex: Int) {
        guard let task = task(for: taskID),
              let surfaceID = task.workspace.surfaceID(atTabIndex: tabIndex)
        else {
            return
        }

        select(surfaceID: surfaceID, forTaskID: taskID)
    }

    func selectLastSurface(taskID: TaskItem.ID) {
        guard let task = task(for: taskID),
              let surfaceID = task.workspace.lastTabSurfaceID
        else {
            return
        }

        select(surfaceID: surfaceID, forTaskID: taskID)
    }

    /// Moves focus to the split pane in `direction` of the currently-selected surface (Ghostty's
    /// `goto_split`). Returns the surface that was focused, or nil if there's no pane that way.
    @discardableResult
    func focusAdjacentSurface(taskID: TaskItem.ID, direction: SplitFocusDirection) -> Surface.ID? {
        guard let task = task(for: taskID),
              let current = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id,
              let neighbor = task.workspace.neighborSurface(of: current, direction: direction)
        else {
            return nil
        }

        select(surfaceID: neighbor, forTaskID: taskID)
        return neighbor
    }

    func createSurface(taskID: TaskItem.ID, title: String, cwd: String, startupCommand: String?) {
        guard let index = taskIndex(for: taskID) else {
            return
        }

        let surface = makeSurface(in: tasks[index], title: title, cwd: cwd, startupCommand: startupCommand)
        // New tab: append a tab at the root, preserving existing tabs and any splits inside them.
        let layoutBeforeAdd = tasks[index].workspace.layout
        tasks[index].workspace.surfaces.append(surface)
        tasks[index].workspace.layout = layoutBeforeAdd.addingTab(.surface(surface.id))
        selectNewSurface(surface.id, inTaskAt: index)
    }

    func createDefaultSurface(taskID: TaskItem.ID) {
        guard let task = task(for: taskID) else {
            return
        }
        createSurface(
            taskID: taskID,
            title: "tab \(task.workspace.surfaces.count + 1)",
            cwd: newSurfaceDirectory(for: task),
            startupCommand: nil
        )
    }

    func createAgentSurface(taskID: TaskItem.ID) {
        guard let task = task(for: taskID),
              let project = project(for: task.projectID),
              let startupCommand = AgentStartupCommandResolver.startupCommand(
                defaultAgentCommand: project.defaultAgentCommand,
                wrapperPath: agentWrapperPath
              )
        else {
            createDefaultSurface(taskID: taskID)
            return
        }
        createSurface(
            taskID: taskID,
            title: "agent \(task.workspace.surfaces.count + 1)",
            cwd: newSurfaceDirectory(for: task),
            startupCommand: startupCommand
        )
    }

    /// A new tab running a specific agent (the `+` menu's "New <agent> Tab"), whatever the project's
    /// default is.
    func createAgentSurface(taskID: TaskItem.ID, profileID: String) {
        guard let task = task(for: taskID),
              let profile = AgentProfiles.named(profileID),
              let startupCommand = AgentStartupCommandResolver.startupCommand(
                  defaultAgentCommand: AgentCommandDefaults.command(for: profile.id),
                  wrapperPath: agentWrapperPath
              )
        else {
            return
        }
        createSurface(taskID: taskID, title: profile.command, cwd: newSurfaceDirectory(for: task), startupCommand: startupCommand)
    }

    func splitSurface(taskID: TaskItem.ID, axis: SplitAxis) {
        guard let index = taskIndex(for: taskID) else {
            return
        }

        let task = tasks[index]
        let count = task.workspace.surfaces.count + 1
        let surface = makeSurface(
            in: task,
            title: axis == .horizontal ? "right \(count)" : "down \(count)",
            cwd: newSurfaceDirectory(for: task),
            startupCommand: nil
        )
        let activeSurfaceID = activeSurface(for: task)?.id ?? surface.id
        let currentLayout = task.workspace.layout
        tasks[index].workspace.surfaces.append(surface)
        // Split within the active surface's tab (tabs stay at the root). The fallback only fires if the
        // active surface somehow isn't in the layout — add it as a tab rather than orphan it.
        tasks[index].workspace.layout = currentLayout.splittingSurface(
            activeSurfaceID,
            axis: axis,
            newSurfaceID: surface.id
        ) ?? currentLayout.addingTab(.surface(surface.id))
        selectNewSurface(surface.id, inTaskAt: index)
    }

    /// Where a new tab or pane starts: the focused tab's folder, else the task's checkout, else home.
    func newSurfaceDirectory(for task: TaskItem) -> String {
        activeSurface(for: task)?.cwd
            ?? task.repoPathOverride?.nilIfBlank
            ?? project(for: task.projectID)?.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// A new surface for a task's workspace: a unique id, the task's terminal environment (with the
    /// task title as the agent's session name), and the launch metadata its command needs.
    private func makeSurface(in task: TaskItem, title: String, cwd: String, startupCommand: String?) -> Surface {
        let cwd = cwd.trimmedForStorage
        let surfaceID = uniqueID(base: title, existingIDs: Set(task.workspace.surfaces.map(\.id)))
        var surface = Surface(
            id: surfaceID,
            workspaceID: task.workspace.id,
            title: title.trimmedForStorage,
            cwd: cwd,
            environment: taskTerminalEnvironment(projectID: task.projectID, cwd: cwd, agentName: task.title),
            startupCommand: startupCommand?.nilIfBlank,
            agentLaunchMetadata: agentLaunchMetadata(startupCommand: startupCommand, cwd: cwd)
        )
        surface.output = [Surface.pwdPlaceholderSeed, cwd]
        return surface
    }

    /// Focuses a surface just added to a task, and follows it on screen when that task is open.
    private func selectNewSurface(_ surfaceID: Surface.ID, inTaskAt index: Int) {
        tasks[index].workspace.selectedSurfaceID = surfaceID
        tasks[index].touchWorkspace()
        if selectedTaskID == tasks[index].id {
            selectedWorkspaceID = tasks[index].workspace.id
            selectedSurfaceID = surfaceID
        }
    }

    func renameSurface(taskID: TaskItem.ID, surfaceID: Surface.ID, title: String) {
        guard let taskIndex = taskIndex(for: taskID),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        tasks[taskIndex].workspace.surfaces[surfaceIndex].title = title.trimmedForStorage
        tasks[taskIndex].touchWorkspace()
    }

    func deleteSurface(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        guard let taskIndex = taskIndex(for: taskID) else {
            return
        }

        // Prunes the layout and moves the selection to the next tab (or the previous one).
        _ = try? tasks[taskIndex].workspace.deleteSurface(id: surfaceID)
        tasks[taskIndex].touchWorkspace()
        if selectedTaskID == taskID {
            selectedWorkspaceID = tasks[taskIndex].workspace.id
            selectedSurfaceID = tasks[taskIndex].workspace.selectedSurfaceID
        }
    }

    /// Reorders the workspace's tabs by moving the tab at `fromOffset` to `toOffset` (insertion index
    /// among the remaining tabs). Reorders whole tabs, so a tab that contains a split moves intact.
    func moveSurfaceTab(taskID: TaskItem.ID, fromOffset: Int, toOffset: Int) {
        guard let taskIndex = taskIndex(for: taskID),
              tasks[taskIndex].workspace.moveTab(from: fromOffset, to: toOffset)
        else {
            return
        }
        tasks[taskIndex].updatedAt = Date()
    }

    func updateSurfaceState(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        title: String,
        cwd: String,
        output: [String]
    ) {
        guard let taskIndex = taskIndex(for: taskID),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        tasks[taskIndex].workspace.surfaces[surfaceIndex].title = title
        tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd = cwd
        tasks[taskIndex].workspace.surfaces[surfaceIndex].output = output
        tasks[taskIndex].touchWorkspace()
    }

    func updateSurfaceMetadata(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        title: String?,
        cwd: String?
    ) {
        guard let taskIndex = taskIndex(for: taskID),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        var changed = false
        if let title, title.isEmpty == false,
           tasks[taskIndex].workspace.surfaces[surfaceIndex].title != title {
            tasks[taskIndex].workspace.surfaces[surfaceIndex].title = title
            changed = true
        }
        if let cwd, cwd.isEmpty == false,
           tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd != cwd {
            tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd = cwd
            changed = true
        }

        guard changed else {
            return
        }

        tasks[taskIndex].touchWorkspace()
    }
}
