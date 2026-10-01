import Foundation
import BalaganCore

struct FixtureDocument: Decodable {
    let fixtureName: String
    let projects: [FixtureProject]
    let tasks: [FixtureTask]
    let workspaces: [FixtureWorkspace]
    let uiState: FixtureUIState

    static func load(from url: URL) throws -> FixtureDocument {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureDocument.self, from: data)
    }

    func makeViewModel(agentWrapperPath: String? = nil, dataSource: String = "fixture") -> BoardViewModel {
        let projects = projects.map {
            Project(
                id: $0.id,
                name: $0.name,
                repoPath: $0.repoPath,
                defaultBranch: $0.defaultBranch,
                defaultAgentCommand: $0.defaultAgentCommand
            )
        }
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let workspacesByTaskID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.taskId, $0) })

        let tasks = tasks.map { fixtureTask in
            let project = projectsByID[fixtureTask.projectId]
            let workspace = workspacesByTaskID[fixtureTask.id]?.makeWorkspace(taskID: fixtureTask.id)
                ?? Workspace.fakeTerminal(
                    taskID: fixtureTask.id,
                    title: "agent",
                    cwd: fixtureTask.repoPathOverride ?? project?.repoPath ?? "/tmp"
                )

            return TaskItem(
                id: fixtureTask.id,
                projectID: fixtureTask.projectId,
                title: fixtureTask.title,
                notes: fixtureTask.description,
                status: TaskStatus(rawValue: fixtureTask.status),
                priority: TaskPriority.fixtureValue(fixtureTask.priority),
                tags: fixtureTask.tags,
                workspace: workspace
            )
        }

        return BoardViewModel(
            projects: projects,
            tasks: tasks,
            selectedProjectID: uiState.selectedProjectId,
            selectedTaskID: uiState.selectedTaskId,
            selectedWorkspaceID: uiState.selectedWorkspaceId,
            selectedSurfaceID: uiState.selectedSurfaceId,
            agentWrapperPath: agentWrapperPath,
            dataSource: dataSource
        )
    }
}

struct FixtureProject: Decodable {
    let id: String
    let name: String
    let repoPath: String
    let defaultBranch: String?
    let defaultAgentCommand: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case repoPath
        case defaultBranch
        case defaultAgentCommand
        case defaultAgentCommandTemplates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        if let command = try container.decodeIfPresent(String.self, forKey: .defaultAgentCommand) {
            defaultAgentCommand = command
        } else {
            let templates = try container.decodeIfPresent([String: String].self, forKey: .defaultAgentCommandTemplates)
            defaultAgentCommand = templates?["codex"] ?? templates?["default"]
        }
    }
}

struct FixtureTask: Decodable {
    let id: String
    let projectId: String
    let title: String
    let description: String
    let status: String
    let priority: Int
    let tags: [String]
    let repoPathOverride: String?
}

struct FixtureWorkspace: Decodable {
    let id: String
    let taskId: String
    let selectedSurfaceId: String?
    let layout: FixtureWorkspaceLayout?
    let lastOpenedAt: String?
    let surfaces: [FixtureSurface]

    func makeWorkspace(taskID: TaskItem.ID) -> Workspace {
        let surfaces = surfaces.map { $0.makeSurface(workspaceID: id) }
        let selectedSurfaceID = selectedSurfaceId ?? surfaces.first?.id

        return Workspace(
            id: id,
            taskID: taskID,
            layout: layout?.makeLayout() ?? .tabs(surfaces.map { .surface($0.id) }),
            selectedSurfaceID: selectedSurfaceID,
            surfaces: surfaces,
            lastOpenedAt: lastOpenedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }
}

struct FixtureWorkspaceLayout: Decodable {
    let kind: String
    let axis: SplitAxis?
    let children: [FixtureWorkspaceLayout]?
    let surfaceId: String?
    let surfaceIds: [String]?

    func makeLayout() -> WorkspaceLayout {
        switch kind {
        case "split":
            return .split(axis: axis ?? .horizontal, children: children?.map { $0.makeLayout() } ?? [])
        case "surface":
            return .surface(surfaceId ?? "")
        case "tabs":
            return .tabs((surfaceIds ?? []).map { .surface($0) })
        default:
            return .single
        }
    }
}

struct FixtureSurface: Decodable {
    let id: String
    let title: String
    let cwd: String
    let startupCommand: String?
    let sanitizedEnv: [String: String]?
    let resumeBinding: FixtureResumeBinding?
    let fakeTerminalOutput: [String]?
    let scrollbackSnapshot: [String]?

    func makeSurface(workspaceID: Workspace.ID) -> Surface {
        let binding = resumeBinding.map {
            $0.makeBinding(surfaceID: id)
        }

        var surface = Surface(
            id: id,
            workspaceID: workspaceID,
            title: title,
            cwd: cwd,
            environment: sanitizedEnv ?? [:],
            startupCommand: startupCommand,
            resumeBinding: binding
        )
        surface.output = fakeTerminalOutput ?? scrollbackSnapshot ?? ["No terminal output in fixture."]
        return surface
    }
}

struct FixtureResumeBinding: Decodable {
    let kind: ResumeKind?
    let agentName: String?
    let capturedSessionId: String?
    let resumeCommand: String
    let trustStatus: ResumeTrust?
    let autoResume: Bool?

    func makeBinding(surfaceID: Surface.ID) -> ResumeBinding {
        ResumeBinding(
            id: "resume-\(surfaceID)",
            surfaceID: surfaceID,
            kind: kind ?? .custom,
            agentName: agentName,
            sessionID: capturedSessionId,
            command: resumeCommand,
            trust: trustStatus ?? .untrusted,
            source: autoResume == true ? .agentHook : .manual,
            autoResume: autoResume ?? false,
            sanitizedEnvironment: [:]
        )
    }

    func makePlan(surfaceID: Surface.ID, taskID: TaskItem.ID, cwd: String) -> ResumeCommandPlan {
        let binding = makeBinding(surfaceID: surfaceID)
        return ResumeCommandPlanner.plan(for: binding, taskID: taskID, cwd: cwd)
    }
}

struct FixtureUIState: Decodable {
    let selectedProjectId: String?
    let selectedTaskId: String?
    let selectedWorkspaceId: String?
    let selectedSurfaceId: String?
}
