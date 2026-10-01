import Foundation
import BalaganCore

/// Terminal-surface lifecycle: tab selection, creation (shell / agent / split), rename, delete,
/// and live state updates. Extracted from `BoardViewModel`; the shared helpers it relies on
/// (`activeSurface`, `replacementSurfaceID`, `selectRelativeSurface`, `agentLaunchMetadata`) remain
/// on the view model.
extension BoardViewModel {
    func setSplitWeights(taskID: TaskItem.ID, key: String, weights: [Double]) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        tasks[index].workspace.setSplitWeights(weights, forKey: key)
        tasks[index].updatedAt = Date()
    }

    func equalizeSplits(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        tasks[index].workspace.equalizeSplits()
        tasks[index].updatedAt = Date()
    }

    func select(surfaceID: Surface.ID, forTaskID taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        guard tasks[index].workspace.surfaces.contains(where: { $0.id == surfaceID }) else {
            return
        }

        tasks[index].workspace.selectedSurfaceID = surfaceID
        tasks[index].workspace.lastOpenedAt = Date()
        tasks[index].updatedAt = Date()
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
        guard let task = tasks.first(where: { $0.id == taskID }),
              let surfaceID = task.workspace.surfaceID(atTabIndex: tabIndex)
        else {
            return
        }

        select(surfaceID: surfaceID, forTaskID: taskID)
    }

    func selectLastSurface(taskID: TaskItem.ID) {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let surfaceID = task.workspace.lastSurfaceID
        else {
            return
        }

        select(surfaceID: surfaceID, forTaskID: taskID)
    }

    /// Moves focus to the split pane in `direction` of the currently-selected surface (Ghostty's
    /// `goto_split`). Returns the surface that was focused, or nil if there's no pane that way.
    @discardableResult
    func focusAdjacentSurface(taskID: TaskItem.ID, direction: SplitFocusDirection) -> Surface.ID? {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let current = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id,
              let neighbor = task.workspace.neighborSurface(of: current, direction: direction)
        else {
            return nil
        }

        select(surfaceID: neighbor, forTaskID: taskID)
        return neighbor
    }

    func createSurface(taskID: TaskItem.ID, title: String, cwd: String, startupCommand: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        let existingIDs = Set(tasks[index].workspace.surfaces.map(\.id))
        let surfaceID = uniqueID(base: title, existingIDs: existingIDs)
        var surface = Surface(
            id: surfaceID,
            workspaceID: tasks[index].workspace.id,
            title: title.trimmedForStorage,
            cwd: cwd.trimmedForStorage,
            environment: taskTerminalEnvironment(
                projectID: tasks[index].projectID,
                cwd: cwd.trimmedForStorage,
                agentName: tasks[index].title
            ),
            startupCommand: startupCommand?.nilIfBlank,
            agentLaunchMetadata: agentLaunchMetadata(
                startupCommand: startupCommand,
                cwd: cwd.trimmedForStorage
            )
        )
        surface.output = [Surface.pwdPlaceholderSeed, cwd.trimmedForStorage]

        // New tab: append a tab at the root, preserving existing tabs and any splits inside them.
        let layoutBeforeAdd = tasks[index].workspace.layout
        tasks[index].workspace.surfaces.append(surface)
        tasks[index].workspace.layout = layoutBeforeAdd.addingTab(.surface(surface.id))
        tasks[index].workspace.selectedSurfaceID = surface.id
        tasks[index].workspace.lastOpenedAt = Date()
        tasks[index].updatedAt = Date()
        if selectedTaskID == taskID {
            selectedWorkspaceID = tasks[index].workspace.id
            selectedSurfaceID = surface.id
        }
    }

    func createDefaultSurface(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        let surfaceNumber = tasks[index].workspace.surfaces.count + 1
        let cwd = activeSurface(for: tasks[index])?.cwd
            ?? project(for: tasks[index].projectID)?.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        createSurface(
            taskID: taskID,
            title: "tab \(surfaceNumber)",
            cwd: cwd,
            startupCommand: nil
        )
    }

    func createAgentSurface(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let project = project(for: tasks[index].projectID),
              let startupCommand = AgentStartupCommandResolver.startupCommand(
                defaultAgentCommand: project.defaultAgentCommand,
                wrapperPath: agentWrapperPath
              )
        else {
            createDefaultSurface(taskID: taskID)
            return
        }

        let surfaceNumber = tasks[index].workspace.surfaces.count + 1
        let cwd = activeSurface(for: tasks[index])?.cwd
            ?? tasks[index].repoPathOverride
            ?? project.repoPath
        createSurface(
            taskID: taskID,
            title: "agent \(surfaceNumber)",
            cwd: cwd,
            startupCommand: startupCommand
        )
    }

    /// A new tab running a specific agent (the `+` menu's "New <agent> Tab"), whatever the project's
    /// default is.
    func createAgentSurface(taskID: TaskItem.ID, profileID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let profile = AgentProfiles.named(profileID),
              let startupCommand = AgentStartupCommandResolver.startupCommand(
                  defaultAgentCommand: AgentCommandDefaults.command(for: profile.id),
                  wrapperPath: agentWrapperPath
              )
        else {
            return
        }
        let cwd = activeSurface(for: tasks[index])?.cwd
            ?? tasks[index].repoPathOverride
            ?? project(for: tasks[index].projectID)?.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        createSurface(taskID: taskID, title: profile.command, cwd: cwd, startupCommand: startupCommand)
    }

    func splitSurface(taskID: TaskItem.ID, axis: SplitAxis) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        let task = tasks[index]
        let activeSurface = activeSurface(for: task)
        let cwd = activeSurface?.cwd
            ?? project(for: task.projectID)?.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let title = axis == .horizontal ? "right \(task.workspace.surfaces.count + 1)" : "down \(task.workspace.surfaces.count + 1)"
        let existingIDs = Set(tasks[index].workspace.surfaces.map(\.id))
        let surfaceID = uniqueID(base: title, existingIDs: existingIDs)
        var surface = Surface(
            id: surfaceID,
            workspaceID: tasks[index].workspace.id,
            title: title,
            cwd: cwd,
            environment: taskTerminalEnvironment(projectID: task.projectID, cwd: cwd),
            startupCommand: nil
        )
        surface.output = [Surface.pwdPlaceholderSeed, cwd]

        let activeSurfaceID = activeSurface?.id ?? surfaceID
        let currentLayout = task.workspace.layout
        tasks[index].workspace.surfaces.append(surface)
        // Split within the active surface's tab (tabs stay at the root). The fallback only fires if the
        // active surface somehow isn't in the layout — add it as a tab rather than orphan it.
        tasks[index].workspace.layout = currentLayout.splittingSurface(
            activeSurfaceID,
            axis: axis,
            newSurfaceID: surfaceID
        ) ?? currentLayout.addingTab(.surface(surfaceID))
        tasks[index].workspace.selectedSurfaceID = surfaceID
        tasks[index].workspace.lastOpenedAt = Date()
        tasks[index].updatedAt = Date()
        if selectedTaskID == taskID {
            selectedWorkspaceID = tasks[index].workspace.id
            selectedSurfaceID = surfaceID
        }
    }

    func renameSurface(taskID: TaskItem.ID, surfaceID: Surface.ID, title: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        tasks[taskIndex].workspace.surfaces[surfaceIndex].title = title.trimmedForStorage
        tasks[taskIndex].workspace.lastOpenedAt = Date()
        tasks[taskIndex].updatedAt = Date()
    }

    func deleteSurface(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        let previousOrderedSurfaceIDs = tasks[taskIndex].workspace.orderedSurfaceIDs
        tasks[taskIndex].workspace.surfaces.removeAll { $0.id == surfaceID }
        let remainingSurfaceIDs = tasks[taskIndex].workspace.surfaces.map(\.id)
        let currentLayout = tasks[taskIndex].workspace.layout
        tasks[taskIndex].workspace.layout = currentLayout.pruningUnavailableSurfaceIDs(remainingSurfaceIDs)
            ?? .tabs(remainingSurfaceIDs.map { .surface($0) })
        if tasks[taskIndex].workspace.selectedSurfaceID == surfaceID
            || tasks[taskIndex].workspace.selectedSurfaceID.map({ remainingSurfaceIDs.contains($0) }) != true {
            tasks[taskIndex].workspace.selectedSurfaceID = replacementSurfaceID(
                afterDeleting: surfaceID,
                previousOrderedSurfaceIDs: previousOrderedSurfaceIDs,
                availableSurfaceIDs: remainingSurfaceIDs
            )
        }

        tasks[taskIndex].workspace.lastOpenedAt = Date()
        tasks[taskIndex].updatedAt = Date()
        if selectedTaskID == taskID {
            selectedWorkspaceID = tasks[taskIndex].workspace.id
            selectedSurfaceID = tasks[taskIndex].workspace.selectedSurfaceID
        }
    }

    /// Reorders the workspace's tabs by moving the tab at `fromOffset` to `toOffset` (insertion index
    /// among the remaining tabs). Reorders whole tabs, so a tab that contains a split moves intact.
    func moveSurfaceTab(taskID: TaskItem.ID, fromOffset: Int, toOffset: Int) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        var tabs = tasks[taskIndex].workspace.layout.tabContents
        guard tabs.indices.contains(fromOffset) else {
            return
        }
        let moved = tabs.remove(at: fromOffset)
        let clamped = min(max(toOffset, 0), tabs.count)
        tabs.insert(moved, at: clamped)

        tasks[taskIndex].workspace.layout = .tabs(tabs)
        // Keep the stored surfaces array in the same visual order (persistence / fallbacks rely on it).
        let newOrder = WorkspaceLayout.tabs(tabs).surfaceIDs()
        let rank = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($1, $0) })
        tasks[taskIndex].workspace.surfaces.sort {
            (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max)
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
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        tasks[taskIndex].workspace.surfaces[surfaceIndex].title = title
        tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd = cwd
        tasks[taskIndex].workspace.surfaces[surfaceIndex].output = output
        tasks[taskIndex].workspace.lastOpenedAt = Date()
        tasks[taskIndex].updatedAt = Date()
    }

    func updateSurfaceOutput(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        output: [String]
    ) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID })
        else {
            return
        }

        guard tasks[taskIndex].workspace.surfaces[surfaceIndex].output != output else {
            return
        }

        tasks[taskIndex].workspace.surfaces[surfaceIndex].output = output
        tasks[taskIndex].workspace.lastOpenedAt = Date()
        tasks[taskIndex].updatedAt = Date()
    }

    func updateSurfaceMetadata(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        title: String?,
        cwd: String?
    ) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
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

        tasks[taskIndex].workspace.lastOpenedAt = Date()
        tasks[taskIndex].updatedAt = Date()
    }
}
