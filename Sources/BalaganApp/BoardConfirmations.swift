import BalaganCore

// The board's one pending form sheet and one pending confirmation, each an enum so `BoardScreen`
// presents them with a single `.sheet(item:)` and a single `.alert`.

/// The single pending board form sheet. One enum + one `.sheet(item:)` replaces four separate
/// `.sheet(item:)` modifiers on the individual drafts. Each case's `id` delegates to its draft so
/// switching between forms re-presents exactly as before.
enum BoardSheet: Identifiable {
    case projectForm(ProjectFormDraft)
    case taskForm(TaskFormDraft)
    case surfaceForm(SurfaceFormDraft)
    case surfaceRename(SurfaceRenameDraft)

    var id: String {
        switch self {
        case .projectForm(let draft): return draft.id
        case .taskForm(let draft): return draft.id
        case .surfaceForm(let draft): return draft.id
        case .surfaceRename(let draft): return draft.id
        }
    }
}

/// The single pending board confirmation. One enum + one `.alert` replaces four separate alert
/// modifiers (SwiftUI honors only one item-alert per view). Each case carries the payload struct that
/// supplies its `message`/`confirmLabel`; the enum adds the per-case `title` used by the shared alert.
enum PendingConfirmation: Identifiable {
    case projectDelete(ProjectDeleteConfirmation)
    case taskDelete(TaskDeleteConfirmation)
    case worktreeRemove(WorktreeRemoveConfirmation)
    case archive(ArchiveConfirmation)

    var id: String {
        switch self {
        case .projectDelete(let payload): return "project-delete-\(payload.projectID)"
        case .taskDelete(let payload): return "task-delete-\(payload.taskID)"
        case .worktreeRemove(let payload): return "worktree-remove-\(payload.taskID)"
        case .archive(let payload): return "archive-\(payload.taskID)"
        }
    }

    var title: String {
        switch self {
        case .projectDelete: return "Delete Project?"
        case .taskDelete: return "Delete Task?"
        case .worktreeRemove: return "Remove Worktree?"
        case .archive: return "Archive Task?"
        }
    }

    var message: String {
        switch self {
        case .projectDelete(let payload): return payload.message
        case .taskDelete(let payload): return payload.message
        case .worktreeRemove(let payload): return payload.message
        case .archive(let payload): return payload.message
        }
    }
}

struct ProjectDeleteConfirmation {
    let projectID: Project.ID
    let projectName: String
    let taskCount: Int

    init(project: Project, taskCount: Int) {
        self.projectID = project.id
        self.projectName = project.name
        self.taskCount = taskCount
    }

    var message: String {
        let taskLabel = taskCount.counted("task")
        return "This removes \"\(projectName)\", \(taskLabel), and all terminal workspaces."
    }
}

struct TaskDeleteConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String?
    let worktreePath: String?
    let worktreeDirty: Bool
    let branch: String?

    init(task: TaskItem, repoPath: String? = nil, worktreePath: String? = nil, worktreeDirty: Bool = false) {
        self.taskID = task.id
        self.taskTitle = task.title
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.worktreeDirty = worktreeDirty
        self.branch = task.branchOrWorktree?.nilIfBlank
    }

    var hasWorktree: Bool { worktreePath != nil }
    var confirmLabel: String { worktreeDirty ? "Delete & Discard" : "Delete" }

    var message: String {
        if worktreeDirty {
            return "This removes \"\(taskTitle)\", its terminal workspace, and its git worktree — which has uncommitted changes that will be discarded. Its branch is deleted too if fully merged."
        }
        if hasWorktree {
            return "This removes \"\(taskTitle)\", its terminal workspace, and its git worktree. Its branch is deleted too if fully merged."
        }
        return "This removes \"\(taskTitle)\" and its terminal workspace."
    }
}

struct WorktreeRemoveConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String
    let worktreePath: String
    let isDirty: Bool
    let branch: String

    var confirmLabel: String { isDirty ? "Remove & Discard" : "Remove Worktree" }

    var message: String {
        let base = "Removes the git worktree for \"\(taskTitle)\" to free space and closes its terminals. Its branch is deleted too if fully merged (kept if it has unmerged commits)."
        return isDirty ? base + " The worktree has uncommitted changes that will be discarded." : base
    }
}

struct ArchiveConfirmation {
    let taskID: TaskItem.ID
    let taskTitle: String
    let repoPath: String?
    let worktreePath: String?
    let isDirty: Bool
    let branch: String?

    var hasWorktree: Bool { worktreePath != nil }
    var confirmLabel: String { isDirty ? "Archive & Discard" : "Archive" }

    var message: String {
        var lines = [
            "\u{201C}\(taskTitle)\u{201D} will be hidden from the board and permanently deleted after \(BoardViewModel.archivedTaskRetentionDays) days. Its terminal sessions will be closed."
        ]
        if isDirty {
            lines.append("Its git worktree has uncommitted changes that will be discarded. Its branch is deleted too if fully merged (kept if it has unmerged commits).")
        } else if hasWorktree {
            lines.append("Its git worktree will be removed and its branch deleted if fully merged (kept if it has unmerged commits).")
        }
        return lines.joined(separator: "\n\n")
    }
}
