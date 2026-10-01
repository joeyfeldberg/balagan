import Foundation
import BalaganCore

/// Built-in sample boards used by fixture and UI-test launch modes.
///
/// Extracted from `BoardViewModel`. Returns plain core domain data; constructing the
/// `BoardViewModel` stays with the view model.
enum BoardFixtures {
    struct Seed {
        var projects: [Project]
        var tasks: [TaskItem]
        var selectedTaskID: TaskItem.ID?
    }

    static func seed(named name: String) -> Seed {
        switch name {
        case "empty-board":
            return Seed(projects: [], tasks: [], selectedTaskID: nil)

        case "resumable-task":
            let project = Project(
                id: "balagan",
                name: "Balagan",
                repoPath: "/Users/dev/code/balagan"
            )
            let task = TaskItem(
                id: "resume-codex",
                projectID: project.id,
                title: "Resume Codex session",
                notes: "Restore a task workspace through a captured Codex session id.",
                status: .doing,
                priority: .high,
                tags: ["codex", "restore"],
                workspace: .resumableCodex(taskID: "resume-codex")
            )
            return Seed(projects: [project], tasks: [task], selectedTaskID: task.id)

        case "multi-project-board":
            return multiProjectSeed(selectFirstTask: false)

        case "reader-transcript":
            let project = Project(
                id: "balagan",
                name: "Balagan",
                repoPath: "/Users/dev/code/balagan"
            )
            let task = TaskItem(
                id: "reader-demo",
                projectID: project.id,
                title: "Reader mode demo",
                notes: "A Claude conversation rendered by reader mode.",
                status: .doing,
                priority: .medium,
                tags: ["reader"],
                workspace: .readerTranscriptDemo(taskID: "reader-demo")
            )
            return Seed(projects: [project], tasks: [task], selectedTaskID: task.id)

        default:
            return multiProjectSeed(selectFirstTask: true)
        }
    }

    /// Writes the reader-mode fixture transcript (Claude session JSONL) to a deterministic temp path.
    static func writeReaderFixtureTranscript() -> String? {
        let path = NSTemporaryDirectory() + "balagan-reader-fixture.jsonl"
        func record(_ object: [String: Any]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let finalResponse = """
        The flow has three stages: routing, hydration, synthesis.

        Routing is the orchestrator. It has a `compare_tool` whose description \
        (`agent/tools/compare_tool.py:17`) only permits calling it when a prior `product_tool` call \
        this conversation already returned `listing_ids` and a `product_rec_group_id` — it's \
        explicitly forbidden to call it cold on product names, since listing ids are opaque hex \
        strings. The orchestrator also picks `response_type=COMPARISON` \
        (`agent/agents/orchestrator.py:90`), so comparison is strictly a follow-up move.

        The tool itself is just hydration. It takes the listing ids (minimum 2) plus the rec group \
        id and calls `build_products_context_info` (`agent/services/product_info_service.py:147`), \
        which fires two GraphQL calls in parallel. That gets stashed on \
        `agent_state.comparison_response`; the orchestrator only sees back a status boolean.

        Synthesis renders it. `_format_comparison_data` \
        (`agent/services/response_synthesis.py:284`) drops the blobs into the prompt as a \
        "Products to Compare" list, and `COMPARISON_INSTRUCTIONS` \
        (`agent/services/response_synthesis_system_prompt.py:367`) drive the output.

        ```python
        if remaining_budget < COMPARE_DEADLINE_SECONDS:
            return CompareResult(status=False)
        ```

        Want me to trace how `product_rec_group_id` gets threaded through?
        """
        let records: [[String: Any]] = [
            [
                "type": "user",
                "timestamp": "2026-07-23T09:00:00.000Z",
                "message": ["role": "user", "content": "Should LegacyCategorization be a Hierarchy/OOC union?"],
            ],
            [
                "type": "assistant",
                "timestamp": "2026-07-23T09:00:05.000Z",
                "message": ["content": [
                    ["type": "text", "text": "Let me look at how that value actually flows."],
                    ["type": "tool_use", "name": "Read", "input": ["file_path": "categorization/__init__.py"]],
                    ["type": "tool_use", "name": "Grep", "input": ["pattern": "out_of_catalog_reason"]],
                ]],
            ],
            [
                "type": "assistant",
                "timestamp": "2026-07-23T09:01:30.000Z",
                "message": ["content": [["type": "text", "text": finalResponse]]],
            ],
        ]
        let lines = records.compactMap(record)
        guard lines.isEmpty == false else { return nil }
        let contents = lines.joined(separator: "\n") + "\n"
        guard (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        return path
    }

    private static func multiProjectSeed(selectFirstTask: Bool) -> Seed {
        let tasksProject = Project(
            id: "balagan",
            name: "Balagan",
            repoPath: "/Users/dev/code/balagan"
        )
        let apiProject = Project(
            id: "acme-api",
            name: "acme-api",
            repoPath: "/Users/dev/code/acme-api"
        )
        let dashboardProject = Project(
            id: "dashboard",
            name: "dashboard",
            repoPath: "/Users/dev/code/dashboard"
        )
        let tasks = [
            TaskItem(
                id: "board-shell",
                projectID: tasksProject.id,
                title: "Build kanban shell",
                notes: "Create the native board, fixture mode, and task detail layout.",
                status: .doing,
                priority: .high,
                tags: ["ui", "fixtures"],
                workspace: .fakeTerminal(taskID: "board-shell", title: "agent", cwd: tasksProject.repoPath)
            ),
            TaskItem(
                id: "deadline-tests",
                projectID: apiProject.id,
                title: "Tighten deadline tests",
                notes: "Audit request-deadline behavior and add focused coverage.",
                status: .todo,
                priority: .medium,
                tags: ["tests"],
                workspace: .fakeTerminal(taskID: "deadline-tests", title: "tests", cwd: apiProject.repoPath)
            ),
            TaskItem(
                id: "trace-review",
                projectID: dashboardProject.id,
                title: "Review trace search UI",
                notes: "Check recent trace filtering regressions and summarize findings.",
                status: .parked,
                priority: .medium,
                tags: ["review", "otel"],
                workspace: .fakeTerminal(taskID: "trace-review", title: "logs", cwd: dashboardProject.repoPath)
            ),
        ]
        return Seed(
            projects: [tasksProject, apiProject, dashboardProject],
            tasks: tasks,
            selectedTaskID: selectFirstTask ? tasks[0].id : nil
        )
    }
}

extension Workspace {
    // MARK: - Fixture workspaces (built-in sample data)

    static func fakeTerminal(taskID: TaskItem.ID, title: String, cwd: String) -> Workspace {
        let workspaceID = "workspace-\(taskID)"
        var surface = Surface(id: title, workspaceID: workspaceID, title: title, cwd: cwd)
        surface.output = [
            Surface.pwdPlaceholderSeed,
            cwd,
            "$ echo BALAGAN_FAKE_TERMINAL_OUTPUT",
            "deterministic fake terminal output",
        ]
        return Workspace(
            id: workspaceID,
            taskID: taskID,
            layout: .tabs([.surface(title)]),
            selectedSurfaceID: title,
            surfaces: [surface]
        )
    }

    /// A surface bound to a Claude session whose transcript is a small fixture JSONL written to the
    /// temp directory — lets reader mode render real markdown headlessly (`--fixture reader-transcript`
    /// + `BALAGAN_SHOW_READER=1`).
    static func readerTranscriptDemo(taskID: TaskItem.ID) -> Workspace {
        let workspaceID = "workspace-\(taskID)"
        let transcriptPath = BoardFixtures.writeReaderFixtureTranscript()
        var surface = Surface(
            id: "agent",
            workspaceID: workspaceID,
            title: "agent",
            cwd: "/Users/dev/code/balagan",
            resumeBinding: ResumeBinding(
                id: "resume-agent",
                surfaceID: "agent",
                kind: .agent,
                agentName: "claude",
                sessionID: "reader-fixture-session",
                command: "claude --resume reader-fixture-session",
                trust: .trusted,
                source: .agentHook,
                transcriptPath: transcriptPath,
                sanitizedEnvironment: [:]
            )
        )
        surface.output = [
            "$ claude",
            "deterministic fake terminal output",
        ]
        return Workspace(
            id: workspaceID,
            taskID: taskID,
            layout: .tabs([.surface("agent")]),
            selectedSurfaceID: "agent",
            surfaces: [surface]
        )
    }

    static func resumableCodex(taskID: TaskItem.ID) -> Workspace {
        let workspaceID = "workspace-\(taskID)"
        var agent = Surface(
            id: "agent",
            workspaceID: workspaceID,
            title: "agent",
            cwd: "/Users/dev/code/balagan",
            resumeBinding: ResumeBinding(
                id: "resume-agent",
                surfaceID: "agent",
                kind: .agent,
                agentName: "codex",
                sessionID: "4f7e-session",
                command: "codex resume 4f7e-session",
                trust: .trusted,
                sanitizedEnvironment: [:]
            )
        )
        agent.output = [
            "$ codex resume 4f7e-session",
            "Restored task context.",
            "Waiting for confirmation before launching trusted command.",
        ]
        var tests = Surface(
            id: "tests",
            workspaceID: workspaceID,
            title: "tests",
            cwd: "/Users/dev/code/balagan",
            resumeBinding: ResumeBinding(
                id: "resume-tests",
                surfaceID: "tests",
                kind: .tmux,
                agentName: nil,
                sessionID: "task_resume_codex",
                command: "tmux attach -t task_resume_codex",
                trust: .untrusted,
                sanitizedEnvironment: [:]
            )
        )
        tests.output = [
            "$ make ui-test",
            "UI fixture mode ready.",
        ]
        return Workspace(
            id: workspaceID,
            taskID: taskID,
            layout: .tabs([.surface("agent"), .surface("tests")]),
            selectedSurfaceID: "agent",
            surfaces: [agent, tests]
        )
    }
}
