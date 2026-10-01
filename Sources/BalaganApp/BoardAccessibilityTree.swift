import Foundation
import BalaganCore

/// Renders the deterministic accessibility-identifier tree used by the UI-test driver.
/// Extracted from `BoardViewModel`; pure read over the current board state.
extension BoardViewModel {
    func debugAccessibilityTree() -> String {
        var lines = [
            "Balagan",
            "sidebar",
            "kanban-board",
            "task-detail",
            "create-project-button",
            "create-task-button",
            "settings-button",
        ]

        if selectedProjectID != nil {
            lines.append("edit-project-button")
        }

        for project in projects {
            lines.append("project-filter-\(project.id) \(project.name)")
            lines.append("project-context-edit-button \(project.name)")
            lines.append("project-context-delete-button \(project.name)")
        }

        for lane in boardLanes {
            lines.append("column-\(lane.status.accessibilitySlug) \(tasks(for: lane.status).count)")
        }

        for task in tasks {
            lines.append("task-card-\(task.id) \(task.title)")
        }

        if let selectedTask {
            lines.append("task-detail-title \(selectedTask.title)")
            lines.append("edit-task-button \(selectedTask.id)")
            lines.append("task-status-control \(selectedTask.status.displayName)")
            for lane in (project(for: selectedTask.projectID)?.lanes ?? Lane.defaults) {
                lines.append("task-status-option-\(lane.status.accessibilitySlug) \(lane.name)")
            }
            lines.append("create-terminal-tab-button \(selectedTask.id)")
            let selectedSurfaceID = selectedTask.workspace.selectedSurfaceID ?? "none"
            lines.append("selected-workspace-\(selectedTask.workspace.id)")
            if let selectedSurfaceID = selectedTask.workspace.selectedSurfaceID {
                lines.append("selected-surface-\(selectedSurfaceID)")
            }
            lines.append("rename-terminal-tab-button \(selectedSurfaceID)")
            lines.append("delete-terminal-tab-button \(selectedSurfaceID)")
            for surface in selectedTask.workspace.surfaces {
                lines.append("terminal-pane-\(surface.id) \(surface.title)")
                if let resumePlan = surface.resumePlan(taskID: selectedTask.id) {
                    lines.append("resume-button-\(surface.id) \(resumePlan.displayCommand)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
