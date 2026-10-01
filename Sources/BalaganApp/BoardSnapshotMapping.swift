import Foundation
import BalaganCore

/// Conversion between the board view-model state and the persisted `BoardSnapshot`.
///
/// After the model collapse the app uses the core domain types directly, so this is mostly identity
/// plus merging the separately-persisted workspaces back onto their tasks on load.
extension BoardViewModel {
    convenience init(snapshot: BoardSnapshot, agentWrapperPath: String? = nil, dataSource: String) {
        let workspacesByTaskID = Dictionary(
            uniqueKeysWithValues: snapshot.boardState.workspaces.map { ($0.taskID, $0) }
        )
        let tasks = snapshot.boardState.tasks.map { task -> TaskItem in
            guard let workspace = workspacesByTaskID[task.id] else {
                return task
            }
            var merged = task
            merged.workspace = workspace
            // Migrate legacy/“inverted” layouts (tabs trapped inside a split) to the canonical Ghostty
            // shape: root tabs, splits inside tabs.
            merged.workspace.canonicalizeLayout()
            return merged
        }

        self.init(
            projects: snapshot.boardState.projects,
            tasks: tasks,
            selectedProjectID: snapshot.uiState.selectedProjectID,
            selectedTaskID: snapshot.uiState.selectedTaskID,
            selectedWorkspaceID: snapshot.uiState.selectedWorkspaceID,
            selectedSurfaceID: snapshot.uiState.selectedSurfaceID,
            terminalAppearance: snapshot.uiState.terminalAppearance,
            uiAppearance: snapshot.uiState.uiAppearance,
            keyboardShortcuts: snapshot.uiState.keyboardShortcuts,
            agentWrapperPath: agentWrapperPath,
            dataSource: dataSource
        )
    }

    func makeSnapshot(savedAt: Date) -> BoardSnapshot {
        let workspaces = tasks.map(\.workspace)
        let boardState = BoardState(projects: projects, tasks: tasks, workspaces: workspaces)
        let selectedWorkspaceID = self.selectedWorkspaceID ?? selectedTask?.workspace.id
        let selectedSurfaceID = self.selectedSurfaceID
            ?? selectedTask?.workspace.selectedSurfaceID
            ?? selectedTask?.workspace.surfaces.first?.id
        return BoardSnapshot(
            savedAt: savedAt,
            boardState: boardState,
            uiState: PersistedUIState(
                selectedProjectID: selectedProjectID,
                selectedTaskID: selectedTaskID,
                selectedWorkspaceID: selectedWorkspaceID,
                selectedSurfaceID: selectedSurfaceID,
                terminalAppearance: terminalAppearance,
                uiAppearance: uiAppearance,
                keyboardShortcuts: keyboardShortcuts
            )
        )
    }
}
