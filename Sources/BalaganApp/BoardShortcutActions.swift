import BalaganCore

/// View-model targets for the app-level keyboard shortcuts wired in `AppTerminalMenu` (the ones that
/// aren't already plain workspace mutations like `createDefaultSurface` / `splitSurface`).
extension BoardViewModel {
    /// Zoom / unzoom the focused pane (⌘⇧⏎). Toggles between the selected surface and no zoom.
    func toggleZoomForSelectedSurface() {
        guard let surfaceID = selectedSurfaceID else { return }
        zoomedSurfaceID = (zoomedSurfaceID == surfaceID) ? nil : surfaceID
    }

    /// Close the currently-focused tab/pane (⌘W): frees its terminal host, then removes the surface.
    func closeSelectedSurface() {
        guard let taskID = selectedTaskID, let surfaceID = selectedSurfaceID else { return }
        if zoomedSurfaceID == surfaceID { zoomedSurfaceID = nil }
        TerminalHostRegistry.shared.close(taskID: taskID, surfaceID: surfaceID)
        deleteSurface(taskID: taskID, surfaceID: surfaceID)
    }

    /// Ask `BoardScreen` to open the create-task form (⌘N). Works from the board or a task.
    func requestNewTask() {
        pendingNewTaskRequest = true
    }
}
