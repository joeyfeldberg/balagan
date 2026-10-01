import Foundation
import BalaganCore

/// Getting to the agents that need you: the sidebar's per-project task list and the "next agent that
/// needs you" jump. Pure ordering lives in `SidebarTaskList` / `AgentAttentionQueue` (Core).
extension BoardViewModel {
    /// Every surface that wants you right now: blocked on you, or finished while you weren't looking.
    /// Slept and archived tasks never count.
    func attentionQueueEntries() -> [AgentAttentionQueue.Entry] {
        var entries: [AgentAttentionQueue.Entry] = []
        for task in tasks where task.isArchived == false && hibernatedTaskIDs.contains(task.id) == false {
            for surface in task.workspace.surfaces {
                let key = hostKey(task.id, surface.id)
                let reason: AgentAttentionQueue.Reason
                if surfaceLifecycle[key] == .needsInput {
                    reason = .waiting
                } else if surfacesNeedingAttention.contains(key) {
                    reason = .finished
                } else {
                    continue
                }
                entries.append(.init(taskID: task.id, surfaceID: surface.id, reason: reason, since: surfaceLifecycleSince[key]))
            }
        }
        return entries
    }

    /// How many agents the sidebar's "need you" row counts.
    var agentsNeedingYouCount: Int {
        attentionQueueEntries().count
    }

    /// Opens the next agent in the attention queue (waiting oldest-first, then finished). Returns
    /// false when there's nowhere to go, so the caller can beep.
    @discardableResult
    func jumpToNextAgentNeedingYou() -> Bool {
        guard let next = AgentAttentionQueue.next(
            after: selectedTaskID,
            surfaceID: selectedSurfaceID,
            in: attentionQueueEntries()
        ),
            let task = tasks.first(where: { $0.id == next.taskID })
        else {
            return false
        }
        select(task: task)
        select(surfaceID: next.surfaceID, forTaskID: next.taskID)
        return true
    }

    /// The tasks listed under a project in the sidebar. A done task stays listed while it's selected
    /// or still has an agent that needs you.
    func sidebarTasks(for project: Project) -> [TaskItem] {
        SidebarTaskList.tasks(for: project, in: tasks) { task in
            task.id == self.selectedTaskID
                || self.taskIsWaiting(task)
                || self.taskNeedsAttention(task)
        }
    }

    func toggleSidebarCollapsed(projectID: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].sidebarCollapsed.toggle()
    }
}
