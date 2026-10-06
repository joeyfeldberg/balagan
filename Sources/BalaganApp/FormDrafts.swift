import Foundation
import BalaganCore

struct ProjectFormDraft: Identifiable {
    var projectID: Project.ID?
    var name: String
    var repoPath: String
    var defaultBranch: String
    var defaultAgentCommand: String
    var worktreesDirectory: String
    var setupCommands: String
    var savedPrompts: [SavedPrompt] = []

    var id: String {
        projectID.map { "project-\($0)" } ?? "project-create"
    }

    var title: String {
        projectID == nil ? "New Project" : "Edit Project"
    }

    var isValid: Bool {
        name.nilIfBlank != nil && repoPath.nilIfBlank != nil
    }

    /// The default sibling worktrees folder shown as the placeholder for the current repo path.
    var defaultWorktreesDirectory: String {
        Project.defaultWorktreesDirectory(forRepoPath: repoPath.nilIfBlank ?? "")
    }

    static func create() -> ProjectFormDraft {
        ProjectFormDraft(
            projectID: nil,
            name: "",
            repoPath: FileManager.default.homeDirectoryForCurrentUser.path,
            defaultBranch: "",
            defaultAgentCommand: AppPreferences.defaultAgent.command ?? "",
            worktreesDirectory: "",
            setupCommands: ""
        )
    }

    static func edit(_ project: Project) -> ProjectFormDraft {
        ProjectFormDraft(
            projectID: project.id,
            name: project.name,
            repoPath: project.repoPath,
            defaultBranch: project.defaultBranch ?? "",
            defaultAgentCommand: project.defaultAgentCommand ?? "",
            worktreesDirectory: project.worktreesDirectory ?? "",
            setupCommands: project.setupCommands ?? "",
            savedPrompts: project.savedPrompts
        )
    }
}

struct TaskFormDraft: Identifiable {
    var taskID: TaskItem.ID?
    var projectID: Project.ID
    var title: String
    var summary: String
    var status: TaskStatus
    var priority: TaskPriority
    var tagsText: String
    var repoPathOverride: String
    var branchOrWorktree: String

    var id: String {
        taskID.map { "task-\($0)" } ?? "task-create"
    }

    var sheetTitle: String {
        taskID == nil ? "New Task" : "Edit Task"
    }

    var isValid: Bool {
        taskID != nil || projectID.isEmpty == false
    }

    var canSave: Bool {
        title.nilIfBlank != nil && projectID.isEmpty == false
    }

    var normalizedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { String($0).trimmedForStorage }
            .filter { !$0.isEmpty }
    }

    static func create(projectID: Project.ID?) -> TaskFormDraft {
        TaskFormDraft(
            taskID: nil,
            projectID: projectID ?? "",
            title: "",
            summary: "",
            status: .todo,
            priority: .medium,
            tagsText: "",
            repoPathOverride: "",
            branchOrWorktree: ""
        )
    }

    static func edit(_ task: TaskItem) -> TaskFormDraft {
        TaskFormDraft(
            taskID: task.id,
            projectID: task.projectID,
            title: task.title,
            summary: task.notes,
            status: task.status,
            priority: task.priority,
            tagsText: task.tags.joined(separator: ", "),
            repoPathOverride: task.repoPathOverride ?? "",
            branchOrWorktree: task.branchOrWorktree ?? ""
        )
    }
}

struct SurfaceFormDraft: Identifiable {
    var taskID: TaskItem.ID
    var title: String
    var cwd: String
    var startupCommand: String

    var id: String {
        "surface-create-\(taskID)"
    }

    var canSave: Bool {
        title.nilIfBlank != nil && cwd.nilIfBlank != nil
    }

    static func create(task: TaskItem, project: Project?, agentWrapperPath: String?) -> SurfaceFormDraft {
        SurfaceFormDraft(
            taskID: task.id,
            title: "agent \(task.workspace.surfaces.count + 1)",
            cwd: task.repoPathOverride ?? project?.repoPath ?? FileManager.default.homeDirectoryForCurrentUser.path,
            startupCommand: AgentStartupCommandResolver.startupCommand(
                defaultAgentCommand: project?.defaultAgentCommand,
                wrapperPath: agentWrapperPath
            ) ?? ""
        )
    }
}

struct SurfaceRenameDraft: Identifiable {
    var taskID: TaskItem.ID
    var surfaceID: Surface.ID
    var title: String

    var id: String {
        "surface-rename-\(taskID)-\(surfaceID)"
    }

    var canSave: Bool {
        title.nilIfBlank != nil
    }

    static func edit(task: TaskItem, surface: Surface) -> SurfaceRenameDraft {
        SurfaceRenameDraft(
            taskID: task.id,
            surfaceID: surface.id,
            title: surface.title
        )
    }
}
