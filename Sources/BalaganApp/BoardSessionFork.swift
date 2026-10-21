import Foundation
import BalaganCore

/// Fork Session: a new tab that continues a tab's agent conversation as a separate session, through
/// the agent's own fork command (`claude --resume <id> --fork-session`, `codex fork <id>`, …). The
/// original tab keeps running untouched. The wrapper binds the new tab to the fork's own session
/// (`AgentWrapperPlanner`), so restarting it reopens the fork, not the original.
extension BoardViewModel {
    /// The agent that can fork this tab's session, or nil when it has no session yet or can't fork.
    func forkableProfile(_ surface: Surface) -> AgentProfile? {
        guard let binding = surface.resumeBinding, binding.kind == .agent,
              let sessionID = binding.sessionID?.nilIfBlank,
              let profile = AgentProfiles.named(binding.agentName) ?? surface.agentKind?.profile,
              profile.forkArgv(sessionID: sessionID) != nil
        else { return nil }
        return profile
    }

    /// Why a tab can't fork, for the menu's disabled state; nil when it can.
    func forkBlocker(_ surface: Surface) -> String? {
        if forkableProfile(surface) != nil { return nil }
        if surface.resumeBinding?.sessionID?.nilIfBlank == nil {
            return "The agent hasn't reported a session yet"
        }
        return "This agent can't fork a session"
    }

    /// Opens the fork in a new tab right after the original and selects it. Returns false when the tab
    /// can't fork.
    @discardableResult
    func forkSession(taskID: TaskItem.ID, surfaceID: Surface.ID) -> Bool {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let source = tasks[taskIndex].workspace.surfaces.first(where: { $0.id == surfaceID }),
              let profile = forkableProfile(source),
              let sessionID = source.resumeBinding?.sessionID,
              let forkArgv = profile.forkArgv(sessionID: sessionID)
        else { return false }

        // Through the wrapper, like every agent tab: `balagan-agent <id> <fork arguments…>`.
        let arguments = forkArgv.dropFirst().map(\.shellQuoted).joined(separator: " ")
        guard let startupCommand = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: "\(AgentCommandDefaults.command(for: profile.id)) \(arguments)",
            wrapperPath: agentWrapperPath
        ) else { return false }

        let sourceTabIndex = tasks[taskIndex].workspace.layout.tabContents
            .firstIndex { $0.surfaceIDs().contains(surfaceID) }
        createSurface(
            taskID: taskID,
            title: "\(TabTitle.agentName(profile.displayName) ?? profile.displayName) fork",
            cwd: source.cwd,
            startupCommand: startupCommand
        )
        // `createSurface` appends the tab; put it right after the one it forked from.
        if let sourceTabIndex {
            let lastTab = tasks[taskIndex].workspace.layout.tabContents.count - 1
            moveSurfaceTab(taskID: taskID, fromOffset: lastTab, toOffset: sourceTabIndex + 1)
        }
        return true
    }
}
