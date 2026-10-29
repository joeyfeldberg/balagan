import Darwin
import BalaganCore

extension BoardViewModel {
    /// The pid of the agent in a tab: its session binding's, or, before the agent has reported a
    /// session (OpenCode before your first message, Codex in its first seconds), the one recorded when
    /// it started.
    func agentPID(taskID: TaskItem.ID, surface: Surface) -> Int32? {
        let pid = surface.resumeBinding?.pid ?? runningAgents[hostKey(taskID, surface.id)]?.pid
        return pid.flatMap { $0 > 0 ? $0 : nil }
    }

    /// SIGTERMs a tab's agent and its process group (a PTY child leads its own group, so this reaches
    /// claude's node children too). Freeing the libghostty surface alone doesn't reliably reap it.
    func terminateAgent(taskID: TaskItem.ID, surface: Surface) {
        guard let pid = agentPID(taskID: taskID, surface: surface) else { return }
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
    }
}
