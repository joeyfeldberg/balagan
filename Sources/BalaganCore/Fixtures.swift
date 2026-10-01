import Foundation

public enum BalaganFixtures {
    public static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    public static let laterDate = Date(timeIntervalSince1970: 1_700_000_600)

    public static func project(
        id: Project.ID = "balagan",
        name: String = "Balagan",
        repoPath: String = "/tmp/balagan",
        defaultBranch: String? = "main",
        defaultAgentCommand: String? = AgentCommandDefaults.codex
    ) -> Project {
        Project(
            id: id,
            name: name,
            repoPath: repoPath,
            defaultBranch: defaultBranch,
            defaultAgentCommand: defaultAgentCommand
        )
    }

    public static func resumeBinding(
        id: ResumeBinding.ID = "resume-terminal",
        taskID: Task.ID? = nil,
        workspaceID: Workspace.ID? = nil,
        surfaceID: Surface.ID = "surface-terminal",
        kind: ResumeKind = .tmux,
        agentName: String? = nil,
        sessionID: String? = "task_build_board",
        command: String = "tmux attach -t task_build_board",
        trust: ResumeTrust = .trusted,
        source: ResumeBindingSource = .manual,
        pid: Int32? = nil,
        executablePath: String? = nil,
        argv: [String] = [],
        cwd: String? = nil,
        capturedAt: Date? = nil,
        captureUpdatedAt: Date? = nil,
        wasRunning: Bool = false,
        isRestorable: Bool = true,
        isStale: Bool = false,
        autoResume: Bool = false,
        transcriptPath: String? = nil,
        sanitizedEnvironment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
        ],
        createdAt: Date = BalaganFixtures.baseDate,
        updatedAt: Date = BalaganFixtures.baseDate
    ) -> ResumeBinding {
        ResumeBinding(
            id: id,
            taskID: taskID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            kind: kind,
            agentName: agentName,
            sessionID: sessionID,
            command: command,
            trust: trust,
            source: source,
            pid: pid,
            executablePath: executablePath,
            argv: argv,
            cwd: cwd,
            capturedAt: capturedAt,
            captureUpdatedAt: captureUpdatedAt,
            wasRunning: wasRunning,
            isRestorable: isRestorable,
            isStale: isStale,
            autoResume: autoResume,
            transcriptPath: transcriptPath,
            sanitizedEnvironment: sanitizedEnvironment,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public static func surface(
        id: Surface.ID = "surface-terminal",
        workspaceID: Workspace.ID = "workspace-build-board",
        title: String = "Terminal",
        cwd: String = "/tmp/balagan",
        environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
        ],
        startupCommand: String? = "tmux new-session -A -s task_build_board -c /tmp/balagan",
        resumeBinding: ResumeBinding? = BalaganFixtures.resumeBinding(),
        scrollbackSnapshot: String? = "$ make test\nAll tests passed",
        agentLaunchMetadata: AgentLaunchMetadata? = nil
    ) -> Surface {
        Surface(
            id: id,
            workspaceID: workspaceID,
            title: title,
            cwd: cwd,
            environment: environment,
            startupCommand: startupCommand,
            resumeBinding: resumeBinding,
            scrollbackSnapshot: scrollbackSnapshot,
            agentLaunchMetadata: agentLaunchMetadata
        )
    }

    public static func workspace(
        id: Workspace.ID = "workspace-build-board",
        taskID: TaskItem.ID = "build-board",
        layout: WorkspaceLayout? = nil,
        selectedSurfaceID: Surface.ID = "surface-terminal",
        surfaces: [Surface]? = nil,
        lastOpenedAt: Date = BalaganFixtures.laterDate
    ) -> Workspace {
        let resolvedSurfaces = surfaces ?? [surface(workspaceID: id)]
        let resolvedLayout = layout ?? .tabs(resolvedSurfaces.map { .surface($0.id) })
        return Workspace(
            id: id,
            taskID: taskID,
            layout: resolvedLayout,
            selectedSurfaceID: selectedSurfaceID,
            surfaces: resolvedSurfaces,
            lastOpenedAt: lastOpenedAt
        )
    }

    public static func task(
        id: TaskItem.ID = "build-board",
        projectID: Project.ID = "balagan",
        title: String = "Build board",
        notes: String = "Fixture task notes",
        status: TaskStatus = .todo,
        priority: TaskPriority = .medium,
        tags: [String] = ["fixture"],
        repoPathOverride: String? = nil,
        branchOrWorktree: String? = "task/build-board",
        workspace: Workspace? = nil,
        createdAt: Date = BalaganFixtures.baseDate,
        updatedAt: Date = BalaganFixtures.baseDate
    ) -> TaskItem {
        TaskItem(
            id: id,
            projectID: projectID,
            title: title,
            notes: notes,
            status: status,
            priority: priority,
            tags: tags,
            repoPathOverride: repoPathOverride,
            branchOrWorktree: branchOrWorktree,
            workspace: workspace ?? BalaganFixtures.workspace(taskID: id),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public static var multiProjectTasks: [TaskItem] {
        [
            task(
                id: "build-board",
                projectID: "balagan",
                title: "Build board",
                status: .todo,
                priority: .high
            ),
            task(
                id: "resume-codex",
                projectID: "balagan",
                title: "Resume Codex session",
                status: .doing,
                priority: .medium
            ),
            task(
                id: "write-docs",
                projectID: "docs",
                title: "Write testing docs",
                status: .done,
                priority: .low
            ),
        ]
    }

    public static func boardState() -> BoardState {
        BoardState(
            projects: [
                project(id: "balagan", name: "Balagan", repoPath: "/tmp/balagan"),
                project(id: "docs", name: "Docs", repoPath: "/tmp/docs"),
            ],
            tasks: multiProjectTasks,
            workspaces: multiProjectTasks.map(\.workspace)
        )
    }
}
