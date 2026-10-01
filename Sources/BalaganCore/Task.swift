import Foundation

public typealias Task = TaskItem

public struct TaskItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var projectID: Project.ID
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var tags: [String]
    public var repoPathOverride: String?
    public var branchOrWorktree: String?
    public var workspace: Workspace
    public var createdAt: Date
    public var updatedAt: Date
    /// Marks the project's ad-hoc "Terminals" workspace (a plain shell rooted at the repo, no agent
    /// or worktree). Hidden from the kanban board; opened from the sidebar. Nil/false = a real task.
    public var projectTerminals: Bool?
    /// When set, the task is archived: hidden from the board and auto-deleted once the retention window
    /// elapses. Nil = active. Optional so older saved boards decode (no key → nil → active).
    public var archivedAt: Date?

    public var isProjectTerminals: Bool { projectTerminals == true }
    public var isArchived: Bool { archivedAt != nil }

    public init(
        id: String,
        projectID: Project.ID,
        title: String,
        notes: String = "",
        status: TaskStatus = .todo,
        priority: TaskPriority = .medium,
        tags: [String] = [],
        repoPathOverride: String? = nil,
        branchOrWorktree: String? = nil,
        workspace: Workspace,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        projectTerminals: Bool? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.tags = tags
        self.repoPathOverride = repoPathOverride
        self.branchOrWorktree = branchOrWorktree
        self.workspace = workspace
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectTerminals = projectTerminals
        self.archivedAt = archivedAt
    }

    public func moved(to status: TaskStatus, at date: Date) -> TaskItem {
        var copy = self
        copy.status = status
        copy.updatedAt = date
        return copy
    }
}

public enum TaskPriority: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }
}

extension TaskItem {
    /// Moves the task to another lane. Any lane is a valid destination now that lanes are user-defined,
    /// so this no longer validates a transition — it's a labelled `moved(to:)`.
    public func transitioned(to destination: TaskStatus, at timestamp: Date) -> TaskItem {
        status == destination ? self : moved(to: destination, at: timestamp)
    }

    public mutating func transition(to destination: TaskStatus, at timestamp: Date) {
        self = transitioned(to: destination, at: timestamp)
    }
}
