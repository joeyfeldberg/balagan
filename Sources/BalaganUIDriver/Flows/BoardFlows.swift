import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func runSettingsFlow() throws {
        try press(identifier: "settings-button")
        try waitForElement(identifier: "decrease-ui-scale-button", timeout: 5)
        try waitForElement(identifier: "increase-ui-scale-button", timeout: 5)
        let resetButton = try waitForElement(identifier: "reset-ui-scale-button", timeout: 5)
        let resetFrameBefore = try frame(of: resetButton)
        try press(identifier: "increase-ui-scale-button")
        let resetFrameAfter = try frame(of: try waitForElement(identifier: "reset-ui-scale-button", timeout: 5))
        guard abs(resetFrameBefore.width - resetFrameAfter.width) < 1,
              abs(resetFrameBefore.height - resetFrameAfter.height) < 1
        else {
            throw DriverError.missingElement("settings popover changed size while open")
        }
        try finishFlow([
            "settingsOpened": true,
            "popoverStableWhileScaling": true,
        ])
    }

    func runNativeFlow() throws {
        try createProject()
        try editProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")
        try editTask()
        try moveTaskToDoing()
        try createTerminalTab()
        try renameTerminalTab()
        try splitTerminalRight()
        try createAndDeleteTransientTerminalTab()

        try finishFlow([
            "projectName": FlowValues.editedProjectName,
            "taskTitle": FlowValues.editedTaskName,
            "taskStatus": FlowValues.status,
            "surfaceTitle": FlowValues.renamedTabTitle,
            "splitTerminal": "completed",
        ])
    }

    func runDailyDriverFlow() throws {
        try createProject()
        try createTask()
        try createOtherProject()
        try selectHarnessProjectFromFullRow()
        try dragTaskToDoing()
        try openTaskWorkspace(identifier: "task-card-harness-task")
        try deleteOnlyTerminalTab()
        try showProjectTasks()
        try editTaskFromContextMenu()
        try deleteTaskFromContextMenu()
        try deleteProjectFromContextMenu()

        try finishFlow([
            "projectName": FlowValues.projectName,
            "taskTitle": FlowValues.contextEditedTaskName,
            "taskStatus": FlowValues.status,
            "statusMoveMethod": "drag-drop",
            "onlyTerminalTabResult": "empty-workspace-or-replacement-state",
            "contextMenuEdit": "completed",
            "contextMenuDelete": "completed",
            "projectFullRowClick": "completed",
            "projectContextMenuEdit": "completed",
            "projectDeleteConfirmationRequired": "completed",
            "projectContextMenuDelete": "completed",
        ])
    }

    func createProject(defaultAgentCommand: String = FlowValues.agentCommand) throws {
        try press(identifier: "create-project-button")
        try setText(identifier: "project-name-field", value: FlowValues.projectName)
        try setText(identifier: "project-repo-path-field", value: FlowValues.repoPath)
        try setText(identifier: "project-default-branch-field", value: FlowValues.defaultBranch)
        try setText(identifier: "project-default-agent-command-field", value: defaultAgentCommand)
        try press(identifier: "project-form-save-button")
        try waitForElement(identifier: "project-filter-harness-project", timeout: 5)
    }

    private func createOtherProject() throws {
        try press(identifier: "create-project-button")
        try setText(identifier: "project-name-field", value: FlowValues.otherProjectName)
        try setText(identifier: "project-repo-path-field", value: FlowValues.otherRepoPath)
        try setText(identifier: "project-default-branch-field", value: FlowValues.defaultBranch)
        try setText(identifier: "project-default-agent-command-field", value: FlowValues.agentCommand)
        try press(identifier: "project-form-save-button")
        try waitForElement(identifier: "project-filter-harness-other-project", timeout: 5)
    }

    private func selectHarnessProjectFromFullRow() throws {
        try clickTrailingEdge(identifier: "project-filter-harness-project")
        try waitForElement(identifier: "task-card-harness-task", timeout: 5)
    }

    private func editProject() throws {
        try press(identifier: "edit-project-button")
        try setText(identifier: "project-name-field", value: FlowValues.editedProjectName)
        try press(identifier: "project-form-save-button")
        sleep(milliseconds: 250)
    }

    func createTask(title: String = FlowValues.taskName) throws {
        try press(identifier: "create-task-button")
        try setText(identifier: "task-title-field", value: title)
        try setTextIfPresent(identifier: "task-notes-field", value: "Created through native accessibility UI smoke.")
        try setText(identifier: "task-tags-field", value: "ui-flow")
        try setText(identifier: "task-branch-field", value: FlowValues.branch)
        try press(identifier: "task-form-save-button")
        try waitForElement(identifier: "task-card-\(title.accessibilitySlug)", timeout: 5)
    }

    func openTaskWorkspace(identifier: String) throws {
        try doubleClick(identifier: identifier)
        try waitForElement(identifier: "task-terminal-workspace", timeout: 5)
    }

    func showProjectTasks() throws {
        try click(identifier: "project-filter-harness-project")
        try waitForElement(identifier: "task-card-harness-task", timeout: 5)
    }

    private func editTask() throws {
        try press(identifier: "edit-task-button")
        try setText(identifier: "task-title-field", value: FlowValues.editedTaskName)
        try setTextIfPresent(identifier: "task-notes-field", value: FlowValues.notes)
        try setText(identifier: "task-tags-field", value: FlowValues.tags)
        try press(identifier: "task-form-save-button")
        sleep(milliseconds: 250)
    }

    private func moveTaskToDoing() throws {
        try selectPicker(identifier: "task-status-control", value: FlowValues.status)
        sleep(milliseconds: 250)
    }

    private func createTerminalTab() throws {
        try press(identifier: "create-terminal-tab-button")
        sleep(milliseconds: 250)
    }

    private func renameTerminalTab() throws {
        try press(identifier: "rename-terminal-tab-button")
        try setText(identifier: "surface-rename-title-field", value: FlowValues.renamedTabTitle)
        try press(identifier: "surface-rename-save-button")
        sleep(milliseconds: 250)
    }

    private func splitTerminalRight() throws {
        try press(identifier: "split-terminal-right-button")
        try waitForElement(identifier: "terminal-pane-right-3", timeout: 5)
    }

    private func createAndDeleteTransientTerminalTab() throws {
        try press(identifier: "create-terminal-tab-button")
        try press(identifier: "rename-terminal-tab-button")
        try setText(identifier: "surface-rename-title-field", value: FlowValues.transientTabTitle)
        try press(identifier: "surface-rename-save-button")
        sleep(milliseconds: 250)
        try press(identifier: "delete-terminal-tab-button")
        sleep(milliseconds: 250)
    }

    private func dragTaskToDoing() throws {
        try dragElement(identifier: "task-card-harness-task", toIdentifier: "column-doing")
        try waitForAnyElement(identifiers: [
            "task-card-harness-task-status-doing",
            "task-card-harness-task-in-doing",
        ], timeout: 5)
    }

    func deleteOnlyTerminalTab() throws {
        try press(identifier: "delete-terminal-tab-button")
        try waitForAnyElement(identifiers: [
            "empty-terminal-workspace",
            "terminal-workspace-empty-state",
            "terminal-tab-replacement-state",
        ], timeout: 5)
    }

    private func editTaskFromContextMenu() throws {
        try showContextMenu(identifier: "task-card-harness-task")
        try pressAny(
            identifiers: ["task-context-edit-button", "context-menu-edit-task"],
            titles: ["Edit Task"]
        )
        try setText(identifier: "task-title-field", value: FlowValues.contextEditedTaskName)
        try press(identifier: "task-form-save-button")
        try waitForElement(identifier: "task-card-harness-daily-context-task-edited", timeout: 5)
    }

    private func deleteTaskFromContextMenu() throws {
        try showContextMenu(identifier: "task-card-harness-daily-context-task-edited")
        try pressAny(
            identifiers: ["task-context-delete-button", "context-menu-delete-task"],
            titles: ["Delete Task"]
        )
        try click(identifier: "task-delete-confirm-button")
        try waitForElementToDisappear(identifier: "task-card-harness-daily-context-task-edited", timeout: 5)
    }

    private func deleteProjectFromContextMenu() throws {
        try showContextMenu(identifier: "project-filter-harness-project", expectedTitles: ["Edit Project", "Delete Project"])
        try pressAny(
            identifiers: ["project-context-edit-button", "context-menu-edit-project"],
            titles: ["Edit Project"]
        )
        try waitForElement(identifier: "project-name-field", timeout: 5)
        try press(identifier: "project-form-cancel-button")

        try showContextMenu(identifier: "project-filter-harness-project", expectedTitles: ["Edit Project", "Delete Project"])
        try pressAny(
            identifiers: ["project-context-delete-button", "context-menu-delete-project"],
            titles: ["Delete Project"]
        )
        try waitForElement(identifier: "project-delete-confirm-button", timeout: 5)
        try waitForElement(identifier: "project-filter-harness-project", timeout: 5)
        try click(identifier: "project-delete-confirm-button")
        try waitForElementToDisappear(identifier: "project-filter-harness-project", timeout: 5)
        try waitForElementToDisappear(identifier: "task-card-harness-task", timeout: 5)
    }

}
