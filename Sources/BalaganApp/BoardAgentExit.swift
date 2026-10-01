import Foundation
import BalaganCore

/// An agent tab whose process has exited and is waiting on the user (see `AgentExitPolicy`).
struct EndedAgent: Equatable {
    enum Offer: Equatable {
        /// The session is saved; Resume picks it up.
        case resume
        /// No session was captured; Start runs the agent again.
        case restart
    }

    var offer: Offer
    var agentName: String
    /// It exited again right after automatic resumes, so Balagan stopped retrying.
    var gaveUpAutoResume: Bool
}

/// What happens when the process in a tab exits: plain shells close their tab; agents are resumed
/// (automatically when they quit right after starting, which is how self-updates look) or keep
/// their tab with a one-key Resume. Rules: `AgentExitPolicy` (Core).
extension BoardViewModel {
    /// A tab's process just started (from the terminal host). Starts the quick-exit clock and clears
    /// any "exited" state left from before.
    func noteSurfaceLaunched(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = hostKey(taskID, surfaceID)
        surfaceLaunchedAt[key] = Date()
        if endedAgents[key] != nil { endedAgents[key] = nil }
    }

    /// Decides and records what a tab's exit means. The caller performs `.closeTab` (it owns the
    /// host); resuming is done here.
    @discardableResult
    func handleEndedProcess(taskID: TaskItem.ID, surfaceID: Surface.ID, now: Date = Date()) -> AgentExitPolicy.Outcome {
        let key = hostKey(taskID, surfaceID)
        guard let surface = tasks.first(where: { $0.id == taskID })?
            .workspace.surfaces.first(where: { $0.id == surfaceID })
        else {
            return .closeTab
        }
        let isAgentTab = surface.resumeBinding?.kind == .agent || surface.agentKind != nil || runningAgents[key] != nil
        let hasSession = surface.resumeBinding?.sessionID?.nilIfBlank != nil
        let history = autoResumeHistory[key] ?? []
        let outcome = AgentExitPolicy.outcome(
            isAgentTab: isAgentTab,
            hasSession: hasSession,
            launchedAt: surfaceLaunchedAt[key],
            now: now,
            recentAutoResumes: history
        )
        let name = Self.agentDisplayName(surface.agentKind ?? AgentKind.named(runningAgents[key]?.name))
        switch outcome {
        case .closeTab:
            break
        case .resumeAutomatically:
            autoResumeHistory[key] = history.filter { now.timeIntervalSince($0) < AgentExitPolicy.autoResumeWindow } + [now]
            showAutoResumeNotice(key, text: "\(name) exited right after starting — probably updating itself — so its session was resumed.")
            relaunchAgent(taskID: taskID, surfaceID: surfaceID)
        case .offerResume, .offerRestart:
            let quick = surfaceLaunchedAt[key].map { now.timeIntervalSince($0) < AgentExitPolicy.quickExitWindow } ?? false
            endedAgents[key] = EndedAgent(
                offer: outcome == .offerResume ? .resume : .restart,
                agentName: name,
                gaveUpAutoResume: quick && outcome == .offerResume
            )
        }
        return outcome
    }

    /// Resume (or start) the agent in an exited tab — the Resume button, ⏎ in the dead terminal.
    func resumeEndedAgent(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = hostKey(taskID, surfaceID)
        guard endedAgents[key] != nil else { return }
        endedAgents[key] = nil
        relaunchAgent(taskID: taskID, surfaceID: surfaceID)
    }

    func dismissEndedAgent(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        endedAgents[hostKey(taskID, surfaceID)] = nil
    }

    func endedAgent(taskID: TaskItem.ID, surfaceID: Surface.ID) -> EndedAgent? {
        endedAgents[hostKey(taskID, surfaceID)]
    }

    private func relaunchAgent(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        agentRelauncher?(taskID, surfaceID)
    }

    private func showAutoResumeNotice(_ key: TerminalHostKey, text: String) {
        agentAutoResumeNotice = (key, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.agentAutoResumeNotice?.key == key { self?.agentAutoResumeNotice = nil }
        }
    }

    static func agentDisplayName(_ kind: AgentKind?) -> String {
        kind?.profile?.displayName ?? "The agent"
    }
}
