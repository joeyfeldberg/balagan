import AppKit
import Darwin
import BalaganCore

/// Manual per-task "sleep" (memory reclamation). Sleeping a task frees every one of its libghostty
/// hosts — reclaiming each surface's renderer, grid and scrollback and terminating the child
/// processes — after snapshotting the visible scrollback into the model so the tabs can be rebuilt.
/// Waking is automatic and needs no special code: reopening the task re-mounts each surface through
/// the normal launch path, which resumes agents (`claude --resume`) and replays a plain shell's
/// captured scrollback — the same path used to reopen a task after an app restart.
///
/// `BoardAutoSleep` drives this same `sleepTask` on its own for quiet tasks.
extension BoardViewModel {
    /// Whether the task has live terminal hosts to sleep (and isn't already asleep).
    @MainActor
    func canSleepTask(taskID: TaskItem.ID) -> Bool {
        hibernatedTaskIDs.contains(taskID) == false
            && TerminalHostRegistry.shared.hasHosts(taskID: taskID)
    }

    /// Puts every tab of a task to sleep. No-op if the task has no live hosts.
    @MainActor
    func sleepTask(taskID: TaskItem.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              TerminalHostRegistry.shared.hasHosts(taskID: taskID)
        else {
            return
        }

        // Capture fresh scrollback from the live hosts *before* freeing them, and write it into the
        // in-memory model so the reopen path can replay it (autosave only ever writes terminal text
        // into the persisted snapshot, never the live model, so the model's copy is otherwise stale).
        let textBySurface = Dictionary(
            TerminalHostRegistry.shared.visibleTextSnapshots(fresh: true)
                .filter { $0.taskID == taskID }
                .map { ($0.surfaceID, $0.text) },
            uniquingKeysWith: { _, latest in latest }
        )
        for surfaceIndex in tasks[taskIndex].workspace.surfaces.indices {
            let surfaceID = tasks[taskIndex].workspace.surfaces[surfaceIndex].id
            if let text = textBySurface[surfaceID], text.isEmpty == false {
                tasks[taskIndex].workspace.surfaces[surfaceIndex].scrollbackSnapshot = text
            }
        }

        // Silence each surface's notification/bell callbacks *before* terminating the agent. A
        // SIGTERM'd `claude`/shell commonly emits a final bell or an OSC desktop-notification on the
        // way out; libghostty delivers that asynchronously, so if we killed first and muted later the
        // escape could still post a banner or light up the attention badge on a task the user just put
        // to sleep. Muting here (synchronously, on the main actor) means the escape lands on nil
        // callbacks. This is the source-level half of the "notifications only for live, awake surfaces"
        // rule; the view-model guards below are the belt to this suspenders.
        TerminalHostRegistry.shared.muteEventCallbacks(taskID: taskID)

        // Explicitly terminate each agent's process (group) before freeing the surface. Freeing the
        // libghostty surface alone does NOT reliably reap the child `claude`/`node` (verified: the pid
        // stayed alive, so the reconciler kept the task "running" while asleep — a slept task showed a
        // spinner, and the memory was never actually reclaimed). Best-effort SIGTERM on the captured
        // pid, and its process group (a PTY child is its own session leader), then clear the
        // working-state so the spinner drops immediately. Also drop any attention flag: a slept task
        // must never carry a "needs attention" badge (and a late edge could otherwise strand one).
        let sleptTaskID = tasks[taskIndex].id
        for surface in tasks[taskIndex].workspace.surfaces {
            if let pid = surface.resumeBinding?.pid, pid > 0 {
                _ = kill(-pid, SIGTERM)   // process group (claude + node children), if pid leads it
                _ = kill(pid, SIGTERM)    // and the process itself
            }
            setSurfaceLifecycle(nil as AgentLifecycle?, taskID: sleptTaskID, surfaceID: surface.id)
            clearSurfaceAttention(taskID: sleptTaskID, surfaceID: surface.id)
            titleWorkingSignals[hostKey(sleptTaskID, surface.id)] = nil
        }

        // Free the hosts (reclaims the renderer/grid/scrollback) and flag the task asleep.
        TerminalHostRegistry.shared.closeTask(taskID: taskID)
        hibernatedTaskIDs.insert(taskID)

        // If it was on screen, drop back to the board so no dead terminal view lingers mounted.
        if selectedTaskID == taskID {
            selectedTaskID = nil
        }
    }

    /// Clears the asleep flag when a task is (re)opened; the reopen/resume path does the actual wake.
    func wakeTaskIfHibernated(taskID: TaskItem.ID) {
        if hibernatedTaskIDs.contains(taskID) {
            hibernatedTaskIDs.remove(taskID)
        }
        autoSleepReasons[taskID] = nil
    }
}
