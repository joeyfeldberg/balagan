import Foundation
import BalaganCore

// App-layer behavior on the core domain types (Surface / Workspace), relocated from the former
// app-side mirror structs (Surface / Workspace) during the model collapse.
//
// Runtime-only state that those mirrors used to store is now derived from the persisted core fields:
//   - `output`     ← computed over `scrollbackSnapshot`
//   - `resumePlan` ← derived from `resumeBinding`
// so there is no separate runtime side-table to keep in sync.

extension Surface {
    /// The placeholder prompt line (`$ pwd`) seeded as the first scrollback line of a freshly created
    /// surface by the non-live fallback view. The scrollback-replay skip-check
    /// (`LibGhosttyTerminalHostView.scrollbackReplayCommand`) matches on it to avoid replaying this
    /// placeholder, so the seeder and the skip-check must reference this one constant.
    static let pwdPlaceholderSeed = "$ pwd"

    /// Terminal scrollback as lines. Backed by the persisted `scrollbackSnapshot`.
    var output: [String] {
        get { scrollbackSnapshot?.split(separator: "\n").map(String.init) ?? [] }
        set { scrollbackSnapshot = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    var liveEnvironment: [String: String] {
        var result = environment
        result["TERM"] = result["TERM"] ?? "xterm-256color"
        return result
    }

    func workspaceID(taskID: TaskItem.ID) -> Workspace.ID {
        workspaceID.isEmpty ? (resumeBinding?.workspaceID ?? "workspace-\(taskID)") : workspaceID
    }

    /// Runtime resume plan, derived from the persisted resume binding.
    func resumePlan(taskID: TaskItem.ID) -> ResumeCommandPlan? {
        resumeBinding.map { ResumeCommandPlanner.plan(for: $0, taskID: taskID, cwd: cwd) }
    }

    func launchAction(
        taskID: TaskItem.ID,
        processPreference: ResumeLaunchProcessPreference = .allowProcessLaunch
    ) -> ResumeLaunchAction {
        ResumeLaunchPolicy.action(for: self, taskID: taskID, processPreference: processPreference)
    }

    func initialLaunchCommand(
        taskID: TaskItem.ID,
        processPreference: ResumeLaunchProcessPreference
    ) -> ResumeLaunchCommand? {
        switch launchAction(taskID: taskID, processPreference: processPreference) {
        case .autoResume(let command), .startupCommand(let command), .startupShell(let command):
            return command
        case .idle, .restoredOnly, .needsConfirmation:
            return nil
        }
    }

    func confirmedResumeCommand(taskID: TaskItem.ID) -> ResumeLaunchCommand? {
        switch launchAction(taskID: taskID) {
        case .autoResume(let command), .needsConfirmation(let command):
            return command
        case .restoredOnly, .idle:
            return resumePlan(taskID: taskID).map {
                ResumeLaunchCommand(
                    surfaceID: id,
                    displayCommand: $0.displayCommand,
                    argv: $0.argv ?? ["/bin/sh", "-lc", $0.displayCommand],
                    environment: environment,
                    workingDirectory: cwd
                )
            }
        case .startupCommand, .startupShell:
            return nil
        }
    }

    func shouldAutoCloseAfterEndedProcessPrompt(
        taskID: TaskItem.ID,
        processPreference: ResumeLaunchProcessPreference
    ) -> Bool {
        switch launchAction(taskID: taskID, processPreference: processPreference) {
        case .autoResume, .startupCommand, .startupShell:
            return true
        case .idle, .restoredOnly, .needsConfirmation:
            return false
        }
    }

    func resumeAffordancePlan(
        taskID: TaskItem.ID,
        processPreference: ResumeLaunchProcessPreference
    ) -> ResumeCommandPlan? {
        guard let plan = resumePlan(taskID: taskID) else {
            return nil
        }

        switch launchAction(taskID: taskID, processPreference: processPreference) {
        case .needsConfirmation, .restoredOnly, .idle:
            return plan
        case .autoResume, .startupCommand, .startupShell:
            return nil
        }
    }
}

extension Workspace {
    /// The former app workspace treated a missing layout as tabbed; core defaults to `.single`,
    /// so normalize `.single` to a tab layout over the current surfaces to preserve behavior.
    private var effectiveLayout: WorkspaceLayout {
        if case .single = layout {
            return .tabs(surfaces.map { .surface($0.id) })
        }
        return layout
    }

    var orderedSurfaceIDs: [Surface.ID] {
        effectiveLayout.orderedSurfaceIDs(availableSurfaceIDs: surfaces.map(\.id))
    }

    var tabSurfaceIDs: [Surface.ID] {
        effectiveLayout.tabSurfaceIDs(availableSurfaceIDs: surfaces.map(\.id))
    }

    var tabSurfaces: [Surface] {
        let surfacesByID = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
        return tabSurfaceIDs.compactMap { surfacesByID[$0] }
    }

    /// The tab-strip entry to highlight: the representative (first) surface of the tab that currently
    /// holds the focused surface — which may be a deeper pane in that tab's split.
    var currentTabRepresentativeSurfaceID: Surface.ID? {
        guard let active = selectedSurfaceID ?? surfaces.first?.id else {
            return nil
        }
        let tab = effectiveLayout.tabContents.first { $0.containsSurface(active) }
        return tab?.firstSurfaceID ?? active
    }

    func surfaceID(after surfaceID: Surface.ID) -> Surface.ID? {
        // Tab navigation (⌘⇧]) cycles tabs only — never split panes (those use split focus).
        tabSurfaceID(after: surfaceID)
    }

    func surfaceID(before surfaceID: Surface.ID) -> Surface.ID? {
        tabSurfaceID(before: surfaceID)
    }

    func surfaceID(atTabIndex index: Int) -> Surface.ID? {
        let tabSurfaceIDs = tabSurfaceIDs
        guard tabSurfaceIDs.indices.contains(index) else {
            return nil
        }
        return tabSurfaceIDs[index]
    }

    var lastSurfaceID: Surface.ID? {
        tabSurfaceIDs.last
    }
}
