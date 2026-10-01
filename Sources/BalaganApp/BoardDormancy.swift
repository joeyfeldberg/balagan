import Foundation
import BalaganCore

/// "Is anything actually running in this task?" A task's terminals only exist once it's opened (or
/// woken) in this run of the app, so after a restart every task is dormant until you open it — the
/// same visible state as one you put to sleep. Cards and sidebar rows show dormancy
/// with the moon and dimming, so live and not-live tasks are told apart at a glance.
extension BoardViewModel {
    /// The task has terminals, and none of them are running right now.
    func taskIsDormant(_ task: TaskItem) -> Bool {
        guard tracksLiveTerminals, task.workspace.surfaces.isEmpty == false else {
            return hibernatedTaskIDs.contains(task.id)
        }
        return liveTaskIDs.contains(task.id) == false
    }

    /// Why a dormant task isn't running, for its tooltip.
    func dormantReason(_ task: TaskItem) -> String {
        if let reason = autoSleepReasons[task.id] { return reason }
        if hibernatedTaskIDs.contains(task.id) { return "Put to sleep" }
        return "Not started since Balagan opened"
    }

    /// Starts a dormant task's terminals in the background — agents resume, shells replay — without
    /// opening it. Nil when the app can't (headless / `--ui-test-mode`).
    var canWakeInBackground: Bool { backgroundTaskWaker != nil }

    func wakeInBackground(taskID: TaskItem.ID) {
        guard let task = tasks.first(where: { $0.id == taskID }), taskIsDormant(task) else { return }
        wakeTaskIfHibernated(taskID: taskID)
        backgroundTaskWaker?(taskID)
    }
}
