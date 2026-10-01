import Foundation
import BalaganCore

enum UIFlowSmokeRecorder {
    private static let schemaVersion = 1
    private static let flowName = "create-edit-status-tab"
    private static let projectID = "harness-project"
    private static let projectName = "Harness Project Edited"
    private static let projectRepoPath = "/tmp/balagan-harness-smoke"
    private static let projectBranch = "harness-main"
    private static let projectAgentCommand = AgentCommandDefaults.codex
    private static let taskID = "harness-task"
    private static let taskTitle = "Harness Task Edited"
    private static let taskNotes = "Edited through the deterministic UI flow smoke."
    private static let taskStatus = TaskStatus.doing
    private static let taskPriority = TaskPriority.high
    private static let taskTags = ["ui-flow", "persisted"]
    private static let taskBranch = "harness-flow-smoke"
    private static let initialSurfaceTitle = "Harness Tab"
    private static let surfaceTitle = "Harness Tab Renamed"
    private static let surfaceID = "harness-tab"
    private static let transientSurfaceTitle = "Harness Delete Tab"
    private static let transientSurfaceID = "harness-delete-tab"
    private static let surfaceCommand = "printf 'harness tab ready\\n'"

    static func applyFlow(to viewModel: BoardViewModel, artifactDirectory: URL?) {
        let project = viewModel.project(for: projectID)
            ?? viewModel.createProject(
                name: "Harness Project",
                repoPath: projectRepoPath,
                defaultBranch: projectBranch,
                defaultAgentCommand: projectAgentCommand,
                worktreesDirectory: nil,
                setupCommands: nil
            )

        viewModel.updateProject(
            id: project.id,
            name: projectName,
            repoPath: projectRepoPath,
            defaultBranch: projectBranch,
            defaultAgentCommand: projectAgentCommand,
            worktreesDirectory: nil,
            setupCommands: nil
        )

        if viewModel.tasks.contains(where: { $0.id == taskID }) {
            viewModel.updateTask(from: taskDraft(projectID: project.id, taskID: taskID))
        } else if let task = viewModel.createTask(from: createTaskDraft(projectID: project.id)) {
            viewModel.updateTask(from: taskDraft(projectID: project.id, taskID: task.id))
        }

        guard let task = viewModel.tasks.first(where: { $0.id == taskID }) else {
            record(phase: "failed", viewModel: viewModel, artifactDirectory: artifactDirectory)
            return
        }

        viewModel.move(task: task, to: taskStatus)

        if let updatedTask = viewModel.tasks.first(where: { $0.id == taskID }),
           updatedTask.workspace.surfaces.contains(where: { $0.id == surfaceID }) == false {
            viewModel.createSurface(
                taskID: updatedTask.id,
                title: initialSurfaceTitle,
                cwd: projectRepoPath,
                startupCommand: surfaceCommand
            )
        }

        if viewModel.tasks.first(where: { $0.id == taskID })?.workspace.surfaces.contains(where: { $0.id == surfaceID }) == true {
            viewModel.renameSurface(taskID: taskID, surfaceID: surfaceID, title: surfaceTitle)
        }

        if let taskWithRenamedSurface = viewModel.tasks.first(where: { $0.id == taskID }),
           taskWithRenamedSurface.workspace.surfaces.contains(where: { $0.id == transientSurfaceID }) == false {
            viewModel.createSurface(
                taskID: taskWithRenamedSurface.id,
                title: transientSurfaceTitle,
                cwd: projectRepoPath,
                startupCommand: nil
            )
        }

        if viewModel.tasks.first(where: { $0.id == taskID })?.workspace.surfaces.contains(where: { $0.id == transientSurfaceID }) == true {
            viewModel.select(surfaceID: surfaceID, forTaskID: taskID)
            viewModel.deleteSurface(taskID: taskID, surfaceID: transientSurfaceID)
        }

        viewModel.selectedProjectID = project.id
        viewModel.selectedTaskID = taskID
        record(phase: "applied", viewModel: viewModel, artifactDirectory: artifactDirectory)
    }

    static func recordObservedState(viewModel: BoardViewModel, artifactDirectory: URL?) {
        guard viewModel.projects.contains(where: { $0.name == projectName })
                || viewModel.tasks.contains(where: { $0.id == taskID })
        else {
            return
        }

        record(phase: "observed", viewModel: viewModel, artifactDirectory: artifactDirectory)
    }

    private static func taskDraft(projectID: Project.ID, taskID: TaskItem.ID?) -> TaskFormDraft {
        TaskFormDraft(
            taskID: taskID,
            projectID: projectID,
            title: taskTitle,
            summary: taskNotes,
            status: .todo,
            priority: taskPriority,
            tagsText: taskTags.joined(separator: ", "),
            repoPathOverride: projectRepoPath,
            branchOrWorktree: taskBranch
        )
    }

    private static func createTaskDraft(projectID: Project.ID) -> TaskFormDraft {
        TaskFormDraft(
            taskID: nil,
            projectID: projectID,
            title: "Harness Task",
            summary: "Created through the deterministic UI flow smoke.",
            status: .todo,
            priority: .medium,
            tagsText: "ui-flow",
            repoPathOverride: projectRepoPath,
            branchOrWorktree: taskBranch
        )
    }

    private static func record(phase: String, viewModel: BoardViewModel, artifactDirectory: URL?) {
        guard let artifactDirectory else {
            return
        }

        let project = viewModel.projects.first { $0.name == projectName }
        let task = viewModel.tasks.first { $0.id == taskID }
        let surface = task?.workspace.surfaces.first { $0.id == surfaceID }
        let payload: [String: Any] = [
            "schemaVersion": schemaVersion,
            "flow": flowName,
            "phase": phase,
            "flowPresent": task != nil && project != nil,
            "expected": expectedPayload(),
            "actual": actualPayload(viewModel: viewModel, project: project, task: task, surface: surface),
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: artifactName(for: phase),
            errorLog: "ui-flow-smoke-error.log",
            failureMessage: "Failed to record UI flow smoke artifact"
        )
    }

    private static func expectedPayload() -> [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "flow": flowName,
            "projectName": projectName,
            "repoPath": projectRepoPath,
            "taskId": taskID,
            "taskTitle": taskTitle,
            "taskStatus": taskStatus.rawValue,
            "taskPriority": taskPriority.rawValue,
            "taskTags": taskTags,
            "selectedSurfaceId": surfaceID,
            "surfaceTitle": surfaceTitle,
            "startupCommand": surfaceCommand,
        ]
    }

    private static func actualPayload(
        viewModel: BoardViewModel,
        project: Project?,
        task: TaskItem?,
        surface: Surface?
    ) -> [String: Any] {
        [
            "dataSource": viewModel.dataSource,
            "projectId": jsonValue(project?.id),
            "projectName": jsonValue(project?.name),
            "repoPath": jsonValue(project?.repoPath),
            "defaultBranch": jsonValue(project?.defaultBranch),
            "defaultAgentCommand": jsonValue(project?.defaultAgentCommand),
            "taskId": jsonValue(task?.id),
            "taskTitle": jsonValue(task?.title),
            "taskNotes": jsonValue(task?.notes),
            "taskStatus": jsonValue(task?.status.displayName),
            "taskPriority": jsonValue(task?.priority.displayName),
            "taskTags": jsonValue(task?.tags),
            "repoPathOverride": jsonValue(task?.repoPathOverride),
            "branchOrWorktree": jsonValue(task?.branchOrWorktree),
            "surfaceIds": jsonValue(task?.workspace.surfaces.map(\.id)),
            "selectedSurfaceId": jsonValue(task?.workspace.selectedSurfaceID),
            "surfaceTitle": jsonValue(surface?.title),
            "surfaceCwd": jsonValue(surface?.cwd),
            "startupCommand": jsonValue(surface?.startupCommand),
            "selectedProjectId": jsonValue(viewModel.selectedProjectID),
            "selectedTaskId": jsonValue(viewModel.selectedTaskID),
            "projectCount": viewModel.projects.count,
            "taskCount": viewModel.tasks.count,
        ]
    }

    private static func artifactName(for phase: String) -> String {
        phase == "observed" ? "ui-flow-observed-state.json" : "ui-flow-smoke.json"
    }

    private static func jsonValue(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func jsonValue(_ value: [String]?) -> Any {
        value ?? NSNull()
    }
}
