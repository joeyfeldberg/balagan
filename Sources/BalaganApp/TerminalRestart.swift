import Darwin
import Foundation
import BalaganCore

/// Restarts a task's agent surface: kills the current process and relaunches it in place, resuming the
/// session from the surface's `ResumeBinding` (or re-running its startup command). Shared by the
/// breadcrumb "Restart Agent" menu and the control-socket `restart` command so both do exactly the
/// same thing. Real libghostty backend only.
enum TerminalRestart {
    /// - Parameter surfaceID: the surface to restart, or nil for the task's selected/first surface.
    /// - Returns: whether a restart was issued.
    @MainActor
    @discardableResult
    static func restart(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID?,
        viewModel: BoardViewModel,
        runtime: TerminalRuntimeOptions,
        artifactDirectory: URL?
    ) -> Bool {
        guard runtime.selection.kind == .libghostty,
              let task = viewModel.tasks.first(where: { $0.id == taskID })
        else {
            return false
        }
        let targetID = surfaceID ?? task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id
        guard let sid = targetID,
              let surface = task.workspace.surfaces.first(where: { $0.id == sid })
        else {
            return false
        }

        // Kill the current agent process (group + pid) before relaunching — freeing the libghostty
        // surface alone doesn't reliably reap the child (same reason sleep SIGTERMs it).
        if let pid = surface.resumeBinding?.pid, pid > 0 {
            _ = kill(-pid, SIGTERM)
            _ = kill(pid, SIGTERM)
        }
        viewModel.setSurfaceLifecycle(nil as AgentLifecycle?, taskID: taskID, surfaceID: sid)

        let config = TerminalSessionConfig(
            taskID: taskID,
            surface: surface,
            runtime: runtime,
            terminalAppearance: viewModel.terminalAppearance,
            artifactDirectory: artifactDirectory
        )
        TerminalHostRegistry.shared.restart(config)
        return true
    }
}
