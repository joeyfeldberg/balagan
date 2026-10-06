import Foundation
import BalaganCore

/// The live activity line on a task card: state + elapsed, the agent's title summary, and a preview
/// of its last response. See `TaskActivity` (Core) for the pure rules.
extension BoardViewModel {
    static let transcriptPreviewQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.transcript-preview", qos: .utility)

    /// What the card should say about the task's agent, or nil for a task with no agent surface (or a
    /// slept one — its moon badge already says everything).
    func taskActivity(_ task: TaskItem) -> TaskActivity? {
        guard hibernatedTaskIDs.contains(task.id) == false else { return nil }
        let agentSurfaces = task.workspace.surfaces.filter { surface in
            surfaceLifecycle[hostKey(task.id, surface.id)] != nil || surface.resumeBinding?.kind == .agent
        }
        let candidates = agentSurfaces.map { surface in
            let key = hostKey(task.id, surface.id)
            return TaskActivity.Candidate(
                surfaceID: surface.id,
                lifecycle: surfaceLifecycle[key],
                since: surfaceLifecycleSince[key],
                isSelected: surface.id == task.workspace.selectedSurfaceID
            )
        }
        guard let surfaceID = TaskActivity.primarySurface(among: candidates),
              let surface = agentSurfaces.first(where: { $0.id == surfaceID })
        else {
            return nil
        }
        let key = hostKey(task.id, surfaceID)
        let activity = TaskActivity(
            lifecycle: surfaceLifecycle[key],
            since: surfaceLifecycleSince[key],
            summary: TaskActivity.summary(fromTitle: surface.title, taskTitle: task.title, cwd: surface.cwd),
            lastResponse: surfaceLastResponses[key],
            isUnseen: surfacesNeedingAttention.contains(key)
        )
        return activity.isEmpty ? nil : activity
    }

    /// Re-reads a surface's last response from its transcript tail, off the main thread. The short
    /// delay lets the agent finish flushing the turn it just ended before we read it.
    func refreshLastResponse(taskID: TaskItem.ID, surfaceID: Surface.ID, delay: TimeInterval = 0.4) {
        guard transcriptPreviewsEnabled,
              let binding = tasks.first(where: { $0.id == taskID })?
                  .workspace.surfaces.first(where: { $0.id == surfaceID })?.resumeBinding,
              binding.kind == .agent
        else {
            return
        }
        let key = hostKey(taskID, surfaceID)
        let token = UUID()
        lastResponseReadTokens[key] = token

        Self.transcriptPreviewQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            let preview = TranscriptLocator.default()
                .resolve(agentName: binding.agentName, sessionID: binding.sessionID, storedPath: binding.transcriptPath)
                .flatMap { path in
                    AgentTranscriptParser.lastAssistantResponse(
                        transcriptAt: path,
                        format: .infer(agentName: binding.agentName, transcriptPath: path)
                    )
                }
                .flatMap { TaskActivity.responsePreview(fromMarkdown: $0) }
            DispatchQueue.main.async {
                guard let self, self.lastResponseReadTokens[key] == token else { return }
                self.lastResponseReadTokens[key] = nil
                // Keep the previous preview if this read found nothing (e.g. a turn that was all tools).
                if let preview, self.surfaceLastResponses[key] != preview {
                    self.surfaceLastResponses[key] = preview
                }
            }
        }
    }

    /// Primes every agent surface's preview — the board after a restart shows what each agent last
    /// said, before any of them reports a new state.
    func refreshAllLastResponses() {
        for task in tasks where task.isArchived == false {
            for surface in task.workspace.surfaces where surface.resumeBinding?.kind == .agent {
                refreshLastResponse(taskID: task.id, surfaceID: surface.id, delay: 0)
            }
        }
    }
}
