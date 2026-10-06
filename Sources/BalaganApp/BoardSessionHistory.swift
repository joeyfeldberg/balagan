import BalaganCore
import Darwin
import Foundation

/// Earlier agent sessions per tab (`Surface.previousSessions`, rules in `SessionHistory`, Core): titles
/// are filled in from the transcripts off-main, and any of them can be made current again and resumed.
extension BoardViewModel {
    static let sessionTitleQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.session-titles", qos: .utility)

    /// Reads a title (the first prompt) for every untitled record in a tab's history.
    func fillSessionTitles(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        guard let records = tasks.first(where: { $0.id == taskID })?
            .workspace.surfaces.first(where: { $0.id == surfaceID })?.previousSessions?
            .filter({ $0.title == nil }), records.isEmpty == false else { return }
        Self.sessionTitleQueue.async { [weak self] in
            let locator = TranscriptLocator.default()
            var titles: [SessionRecord.ID: String] = [:]
            for record in records {
                let binding = record.binding
                guard let path = locator.resolve(agentName: binding.agentName, sessionID: binding.sessionID, storedPath: binding.transcriptPath),
                      let title = SessionHistory.title(
                          transcriptAt: path,
                          format: .infer(agentName: binding.agentName, transcriptPath: path)
                      ) else { continue }
                titles[record.id] = title
            }
            guard titles.isEmpty == false else { return }
            DispatchQueue.main.async {
                guard let self,
                      let taskIndex = self.tasks.firstIndex(where: { $0.id == taskID }),
                      let surfaceIndex = self.tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID }),
                      var history = self.tasks[taskIndex].workspace.surfaces[surfaceIndex].previousSessions else { return }
                for index in history.indices {
                    if let title = titles[history[index].id] { history[index].title = title }
                }
                self.tasks[taskIndex].workspace.surfaces[surfaceIndex].previousSessions = history
            }
        }
    }

    /// At launch: titles for any records saved before they had one.
    func fillAllSessionTitles() {
        for task in tasks {
            for surface in task.workspace.surfaces where surface.previousSessions?.contains(where: { $0.title == nil }) == true {
                fillSessionTitles(taskID: task.id, surfaceID: surface.id)
            }
        }
    }

    /// Makes an earlier session the tab's current one (the current goes into the history). The
    /// caller then restarts the tab, which resumes the session now bound to it.
    @discardableResult
    func switchToPreviousSession(taskID: TaskItem.ID, surfaceID: Surface.ID, recordID: SessionRecord.ID) -> Bool {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID }) else { return false }
        let surface = tasks[taskIndex].workspace.surfaces[surfaceIndex]
        guard let switched = SessionHistory.switching(
            to: recordID,
            current: surface.resumeBinding,
            history: surface.previousSessions ?? [],
            at: Date()
        ) else { return false }
        // Stop the agent that's running now while its pid is still the current one; the restart
        // that follows only knows the switched-to session, which has no live process.
        if let pid = surface.resumeBinding?.pid, pid > 0 {
            _ = kill(-pid, SIGTERM)
            _ = kill(pid, SIGTERM)
        }
        tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding = switched.current
        tasks[taskIndex].workspace.surfaces[surfaceIndex].previousSessions = switched.history.isEmpty ? nil : switched.history
        tasks[taskIndex].updatedAt = Date()
        fillSessionTitles(taskID: taskID, surfaceID: surfaceID)
        return true
    }
}
