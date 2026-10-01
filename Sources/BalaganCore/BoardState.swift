import Foundation

public struct BoardState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [Task]
    public var workspaces: [Workspace]

    public init(
        projects: [Project] = [],
        tasks: [Task] = [],
        workspaces: [Workspace] = []
    ) {
        self.projects = projects
        self.tasks = tasks
        self.workspaces = workspaces
    }

    public func project(id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    public func task(id: Task.ID) -> Task? {
        tasks.first { $0.id == id }
    }

    public func tasks(forProjectID projectID: Project.ID?) -> [Task] {
        guard let projectID else {
            return tasks
        }

        return tasks.filter { $0.projectID == projectID }
    }

    public func tasks(for project: Project) -> [Task] {
        tasks(forProjectID: project.id)
    }

    public func workspace(forTaskID taskID: Task.ID) -> Workspace? {
        workspaces.first { $0.taskID == taskID }
    }

    public func workspace(id: Workspace.ID) -> Workspace? {
        workspaces.first { $0.id == id }
    }
}

public enum BoardStateMutationError: Error, Equatable, Sendable {
    case projectNotFound(Project.ID)
    case taskNotFound(Task.ID)
    case workspaceNotFound(Workspace.ID)
    case surfaceNotFound(Surface.ID)
}

extension BoardStateMutationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .projectNotFound(projectID):
            return "Project not found: \(projectID)."
        case let .taskNotFound(taskID):
            return "Task not found: \(taskID)."
        case let .workspaceNotFound(workspaceID):
            return "Workspace not found: \(workspaceID)."
        case let .surfaceNotFound(surfaceID):
            return "Surface not found: \(surfaceID)."
        }
    }
}

extension BoardState {
    @discardableResult
    public mutating func deleteProject(id projectID: Project.ID) throws -> Project {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw BoardStateMutationError.projectNotFound(projectID)
        }

        let removed = projects.remove(at: projectIndex)
        let removedTaskIDs = Set(tasks.filter { $0.projectID == projectID }.map(\.id))
        tasks.removeAll { $0.projectID == projectID }
        workspaces.removeAll { removedTaskIDs.contains($0.taskID) }
        return removed
    }

    public mutating func moveTask(id taskID: Task.ID, to status: TaskStatus, at date: Date) throws {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw BoardStateMutationError.taskNotFound(taskID)
        }

        tasks[taskIndex] = tasks[taskIndex].moved(to: status, at: date)
    }

    @discardableResult
    public mutating func deleteTask(id taskID: Task.ID) throws -> Task {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw BoardStateMutationError.taskNotFound(taskID)
        }

        let removed = tasks.remove(at: taskIndex)
        workspaces.removeAll { $0.taskID == taskID }
        return removed
    }

    @discardableResult
    public mutating func deleteWorkspace(id workspaceID: Workspace.ID, at date: Date = Date()) throws -> Workspace {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw BoardStateMutationError.workspaceNotFound(workspaceID)
        }

        let removed = workspaces[workspaceIndex]
        workspaces.removeAll { $0.id == workspaceID }
        for taskIndex in tasks.indices where tasks[taskIndex].workspace.id == workspaceID {
            tasks[taskIndex].workspace = removed.empty(forTaskID: tasks[taskIndex].id)
            tasks[taskIndex].updatedAt = date
        }
        return removed
    }

    @discardableResult
    public mutating func deleteSurface(
        id surfaceID: Surface.ID,
        fromWorkspaceID workspaceID: Workspace.ID,
        at date: Date
    ) throws -> Surface {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw BoardStateMutationError.workspaceNotFound(workspaceID)
        }

        let removed = try workspaces[workspaceIndex].deleteSurface(id: surfaceID)
        syncTaskWorkspace(workspaces[workspaceIndex], updatedAt: date)
        return removed
    }

    @discardableResult
    public mutating func deleteSurface(
        id surfaceID: Surface.ID,
        fromTaskID taskID: Task.ID,
        at date: Date
    ) throws -> Surface {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw BoardStateMutationError.taskNotFound(taskID)
        }

        let removed = try tasks[taskIndex].workspace.deleteSurface(id: surfaceID)
        tasks[taskIndex].updatedAt = date
        upsertWorkspace(tasks[taskIndex].workspace)
        return removed
    }

    private mutating func syncTaskWorkspace(_ workspace: Workspace, updatedAt date: Date) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == workspace.taskID }) else {
            return
        }

        tasks[taskIndex].workspace = workspace
        tasks[taskIndex].updatedAt = date
    }

    private mutating func upsertWorkspace(_ workspace: Workspace) {
        if let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[workspaceIndex] = workspace
        } else {
            workspaces.append(workspace)
        }
    }
}
