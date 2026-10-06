import AppKit
import BalaganCore

extension BalaganApplication {
    // MARK: - Control socket (the `balagan` CLI)

    /// Starts the control socket that the `balagan` CLI connects to. Listens at a stable, well-known
    /// path (`~/.balagan/control.sock` unless overridden) so the CLI can find the app with no
    /// configuration. Best-effort: a failure here never blocks app launch.
    func startControlServer(options: LaunchOptions, viewModel: BoardViewModel) {
        let path = options.controlSocketPath ?? ControlSocket.defaultPath()
        do {
            // The server hops to the main thread before invoking this handler (see ControlSocketServer),
            // so it's safe to touch the view model / window here. We serialize to Data so the result is
            // Sendable across the queue boundary.
            let server = try ControlSocketServer(socketPath: path) { [weak self] method, params in
                let response = self?.handleControlCommand(method: method, params: params)
                    ?? ["ok": false, "error": "app not ready"]
                return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
                    ?? Data(#"{"ok":false,"error":"failed to encode response"}"#.utf8)
            }
            controlServer = server
            server.start()
        } catch {
            NSLog("Balagan control server failed to start at \(path): \(error)")
        }
    }

    private func ok(_ result: Any) -> [String: Any] { ["ok": true, "result": result] }
    private func err(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

    /// Routes one CLI command to the view model / window. Always invoked on the main actor (the
    /// control server hops to main before calling it).
    @MainActor
    private func handleControlCommand(method: String, params: [String: String]) -> [String: Any] {
        guard let viewModel else { return err("app not ready") }

        switch method {
        case "ping":
            return ok(["pong": true, "version": appVersionString])
        case "projects":
            return controlProjects(viewModel: viewModel)
        case "tasks":
            return controlTasks(params: params, viewModel: viewModel)
        case "task.create":
            return controlCreateTask(params: params, viewModel: viewModel)
        case "task.open", "open":
            return controlOpenTask(params: params, viewModel: viewModel)
        case "task.state", "state":
            return controlTaskState(params: params, viewModel: viewModel)
        case "task.restart", "restart":
            return controlRestart(params: params, viewModel: viewModel)
        case "status":
            return controlStatus(viewModel: viewModel)
        case "reader.toggle":
            return controlToggleReader(viewModel: viewModel)
        case "task.speak":
            return controlSpeak(params: params, viewModel: viewModel)
        case "autosleep":
            return controlAutoSleep(params: params, viewModel: viewModel)
        case "usage":
            return controlUsage(viewModel: viewModel)
        case "terminal.search":
            return controlTerminalSearch(params: params)
        case "task.send", "task.prompt":
            guard let id = params["id"]?.nilIfBlank, let task = viewModel.tasks.first(where: { $0.id == id }) else {
                return err("task not found: \(params["id"] ?? "")")
            }
            let text: String
            if method == "task.prompt" {
                let title = params["title"] ?? ""
                guard let prompt = viewModel.savedPrompts(for: task).first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else {
                    let titles = viewModel.savedPrompts(for: task).map(\.title).joined(separator: ", ")
                    return err("no saved prompt titled \"\(title)\" (have: \(titles))")
                }
                text = prompt.text
            } else {
                text = params["text"] ?? ""
            }
            if let blocker = viewModel.agentSendBlocker(taskID: id) { return err(blocker) }
            return viewModel.sendToAgent(taskID: id, text: text) ? ok(["sent": true]) : err("couldn't send")
        case "review.send":
            // Unlisted: sends a task's pending diff comments to its agent (the Changes view's button).
            guard let id = params["id"]?.nilIfBlank ?? viewModel.selectedTaskID else { return err("review.send requires --id <task>") }
            if let blocker = viewModel.reviewSendBlocker(taskID: id) { return err(blocker) }
            return viewModel.sendReviewComments(taskID: id) ? ok(["sent": true]) : err("couldn't send")
        default:
            return err("unknown method: \(method)")
        }
    }

    /// `usage` — each agent's subscription limits, as last reported. Read fresh (it's two small file
    /// reads) so the CLI never shows numbers older than the agents' own last report.
    @MainActor
    private func controlUsage(viewModel: BoardViewModel) -> [String: Any] {
        let now = Date()
        let reported = viewModel.usageTrackingEnabled
            ? [AgentUsageStore.readClaude(), AgentUsageStore.readCodex()].compactMap { $0 }
            : viewModel.agentUsage
        let agents: [[String: Any]] = reported.map { $0.current(at: now) }.map { usage in
            [
                "agent": usage.agent,
                "name": SidebarUsageMeter.displayName(usage.agent),
                "plan": usage.plan ?? "",
                "notes": usage.notes,
                "observedAt": ISO8601DateFormatter().string(from: usage.observedAt),
                "windows": usage.windows.map { window in
                    [
                        "label": window.label,
                        "title": window.longLabel,
                        "usedPercent": window.usedPercent,
                        "resetsAt": ISO8601DateFormatter().string(from: window.resetsAt),
                        "resets": SidebarUsageMeter.resetDescription(window, now: now),
                        "hasReset": window.hasReset,
                    ] as [String: Any]
                },
            ]
        }
        return ok(["agents": agents])
    }

    /// `terminal.search` (a dotted, unlisted method) — drives the focused pane's find bar: `text`
    /// searches, `next=1` steps, `end=1` closes; replies with libghostty's last counts. The seam for
    /// verifying search without a keyboard.
    @MainActor
    private func controlTerminalSearch(params: [String: String]) -> [String: Any] {
        guard let host = TerminalHostRegistry.shared.activeHost() else { return err("no focused terminal") }
        if params["end"] != nil {
            host.endSearch()
        } else if params["next"] != nil {
            _ = host.surfaceHandle?.performBindingAction("navigate_search:next")
        } else {
            host.startSearch(needle: params["text"] ?? "")
        }
        var result: [String: Any] = ["open": host.searchBar != nil]
        if let total = host.searchTotal { result["total"] = total }
        if let selected = host.searchSelected { result["selected"] = selected }
        return ok(result)
    }

    /// What auto-sleep sees for each task with live terminals, and what it would sleep right now.
    /// `--now` performs that pass instead of just reporting it.
    @MainActor
    private func controlAutoSleep(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        let now = Date()
        let minutes = viewModel.autoSleepIdleMinutes
        let inputs = viewModel.tasks
            .filter { $0.isArchived == false && TerminalHostRegistry.shared.hasHosts(taskID: $0.id) }
            .map { viewModel.autoSleepInput(for: $0, now: now) }
        let wouldSleep = AutoSleepPlanner.tasksToSleep(
            inputs,
            now: now,
            idleThreshold: viewModel.autoSleepIdleThreshold,
            underMemoryPressure: false
        )
        let slept = params["now"] != nil ? viewModel.runAutoSleep(now: now) : []
        let tasks: [[String: Any]] = inputs.map { input in
            [
                "id": input.taskID,
                "idleSeconds": Int(now.timeIntervalSince(input.lastActiveAt)),
                "onScreen": input.isOnScreen,
                "unseenResult": input.hasUnseenResult,
                "safe": AutoSleepPlanner.isSafeToSleep(input),
                "surfaces": input.surfaces.map { "\($0)" },
            ]
        }
        return ok([
            "idleMinutes": minutes,
            "tasks": tasks,
            "wouldSleep": wouldSleep,
            "slept": slept,
        ])
    }

    @MainActor
    private func controlToggleReader(viewModel: BoardViewModel) -> [String: Any] {
        guard viewModel.selectedTask != nil else { return err("no task selected") }
        viewModel.toggleReaderMode()
        return ok(["readerMode": viewModel.showingReaderMode])
    }

    /// Speaks the last agent response of a task's active surface. `--dry-run` returns the speakable
    /// text instead of playing audio — the headless-verifiable seam for the whole extraction pipeline.
    @MainActor
    private func controlSpeak(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        let task: TaskItem
        if let id = params["id"]?.nilIfBlank {
            guard let found = viewModel.tasks.first(where: { $0.id == id }) else {
                return err("task not found: \(id)")
            }
            task = found
        } else if let selected = viewModel.selectedTask {
            task = selected
        } else {
            return err("no task selected (pass a task id)")
        }

        guard let surface = viewModel.activeSurface(of: task) else {
            return err("task has no terminal surface")
        }
        guard let source = viewModel.readerTranscriptSource(for: surface) else {
            return err("no agent transcript for task \(task.id)")
        }
        guard let contents = try? String(contentsOfFile: source.path, encoding: .utf8),
              let response = AgentTranscriptParser.lastAssistantResponse(
                  in: AgentTranscriptParser.entries(fromJSONL: contents, format: source.format)
              )
        else {
            return err("no assistant response in transcript \(source.path)")
        }

        let sentences = SpeakableText.sentences(fromMarkdown: response)
        if params["dry-run"]?.nilIfBlank != nil {
            return ok([
                "task": task.id,
                "transcript": source.path,
                "sentenceCount": sentences.count,
                "text": sentences.joined(separator: " "),
            ])
        }
        SpeechController.shared.speak(markdown: response)
        return ok(["task": task.id, "speaking": true, "sentenceCount": sentences.count])
    }

    @MainActor
    private func controlProjects(viewModel: BoardViewModel) -> [String: Any] {
        ok([
            "projects": viewModel.projects.map { project in
                ["id": project.id, "name": project.name, "repoPath": project.repoPath]
            },
        ])
    }

    @MainActor
    private func controlTasks(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        let filter = params["project"]?.nilIfBlank
        let rows = viewModel.tasks
            .filter { filter == nil || $0.projectID == filter }
            .map { task -> [String: Any] in
                [
                    "id": task.id,
                    "title": task.title,
                    "project": task.projectID,
                    "status": task.status.rawValue,
                    "branch": task.branchOrWorktree.map { $0 as Any } ?? NSNull(),
                    "running": viewModel.taskIsRunning(task),
                    "live": viewModel.taskIsDormant(task) == false,
                    "exitedAgent": task.workspace.surfaces.contains { viewModel.endedAgent(taskID: task.id, surfaceID: $0.id) != nil },
                    "ports": (viewModel.devServerPorts[task.id] ?? []).map(\.port),
                    "tokens": viewModel.taskTokenUsage[task.id].map { usage -> [String: Any] in
                        var json: [String: Any] = [
                            "total": usage.totalTokens, "input": usage.inputTokens, "cacheWrite": usage.cacheWriteTokens,
                            "cacheRead": usage.cacheReadTokens, "output": usage.outputTokens, "models": usage.models.sorted(),
                        ]
                        if let cost = usage.costUSD { json["costUSD"] = (cost * 100).rounded() / 100 }
                        return json
                    } ?? NSNull(),
                    // The agent in each agent tab: from its session binding, or running but not yet bound.
                    "agents": task.workspace.surfaces.compactMap { surface -> String? in
                        if let name = surface.resumeBinding?.agentName, surface.resumeBinding?.kind == .agent {
                            return "\(name):\(surface.resumeBinding?.sessionID ?? "-")"
                        }
                        return viewModel.runningAgents[viewModel.hostKey(task.id, surface.id)].map { "\($0.name):pending" }
                    },
                    "needsAttention": viewModel.taskNeedsAttention(task),
                ]
            }
        return ok(["tasks": rows])
    }

    @MainActor
    private func controlCreateTask(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        guard let projectID = params["project"]?.nilIfBlank, viewModel.project(for: projectID) != nil else {
            return err("unknown or missing --project")
        }
        guard let title = params["title"]?.nilIfBlank else { return err("missing --title") }
        var draft = TaskFormDraft.create(projectID: projectID)
        draft.title = title
        if let notes = params["notes"]?.nilIfBlank { draft.summary = notes }
        if let branch = params["branch"]?.nilIfBlank { draft.branchOrWorktree = branch }
        if let raw = params["status"]?.nilIfBlank {
            let lanes = viewModel.project(for: projectID)?.lanes ?? Lane.defaults
            guard lanes.contains(where: { $0.id == raw }) else {
                return err("invalid --status \(raw) (expected one of: \(lanes.map(\.id).joined(separator: ", ")))")
            }
            draft.status = TaskStatus(rawValue: raw)
        }
        if let raw = params["priority"]?.nilIfBlank {
            guard let priority = TaskPriority(rawValue: raw) else {
                return err("invalid --priority \(raw) (expected one of: \(TaskPriority.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            draft.priority = priority
        }
        // The CLI creates in the background (don't change the app's current view). `--eager` creates
        // the git worktree now instead of lazily on first open, and launches the agent in the
        // background (below) so an orchestrator can message it without opening the task.
        let eager = params["eager"] != nil
        guard let task = viewModel.createTask(from: draft, selectsOnBoard: false, eagerWorktree: eager)
        else {
            return err("failed to create task")
        }
        // Everything-eager: start the agent off-screen. It comes up asynchronously (its SessionStart
        // report sets the ResumeBinding); the caller waits for readiness with
        // `balagan wait <id> --until idle`. The agent's messaging name is the task title.
        if eager {
            launchAgentSurfaceInBackground(taskID: task.id)
        }
        persistBoardState()
        return ok([
            "id": task.id,
            "title": task.title,
            "project": task.projectID,
            "name": task.title,
            "agentLaunching": eager,
        ])
    }

    /// Starts a task's agent surface in the background — no selection, no on-screen mount — so an
    /// orchestrator that created the task with `--eager` can reach the agent via cross-session
    /// messaging without opening it. Real libghostty backend only (headless / `--ui-test-mode` runs
    /// skip it, since there's no display to mount a surface on); a no-op if the surface has no agent
    /// command or a host already exists.
    @MainActor
    func launchAgentSurfaceInBackground(taskID: TaskItem.ID) {
        guard let viewModel,
              let runtime = terminalRuntime, runtime.selection.kind == .libghostty,
              let task = viewModel.tasks.first(where: { $0.id == taskID }),
              let surface = task.workspace.surfaces.first,
              surface.startupCommand?.nilIfBlank != nil,
              TerminalHostRegistry.shared.hasHosts(taskID: taskID) == false
        else { return }
        let config = TerminalSessionConfig(
            taskID: taskID,
            surface: surface,
            runtime: runtime,
            terminalAppearance: viewModel.terminalAppearance,
            artifactDirectory: launchOptions?.artifactDirectory
        )
        TerminalHostRegistry.shared.launch(config)
    }

    /// Wakes a dormant task off-screen: every tab gets its terminal back (agents resume their session,
    /// shells replay their scrollback), exactly as if it had been opened, but nothing is selected.
    @MainActor
    func launchTaskInBackground(taskID: TaskItem.ID) {
        guard let viewModel,
              let runtime = terminalRuntime, runtime.selection.kind == .libghostty,
              let task = viewModel.tasks.first(where: { $0.id == taskID })
        else { return }
        viewModel.ensureWorktreeCreated(taskID: taskID)
        viewModel.repairMissingWorkingDirectories(taskID: taskID)
        for surface in task.workspace.surfaces {
            TerminalHostRegistry.shared.launch(TerminalSessionConfig(
                taskID: taskID,
                surface: surface,
                runtime: runtime,
                terminalAppearance: viewModel.terminalAppearance,
                artifactDirectory: launchOptions?.artifactDirectory
            ))
        }
    }

    @MainActor
    private func controlOpenTask(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        guard let id = params["id"]?.nilIfBlank, let task = viewModel.tasks.first(where: { $0.id == id }) else {
            return err("task not found: \(params["id"] ?? "")")
        }
        viewModel.select(task: task)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return ok(["opened": id])
    }

    /// `state <task-id>` — the task's aggregate agent state (running / needs-input / idle / asleep /
    /// none). The `wait` CLI polls this so an orchestrator can block until a sub-agent it directed
    /// settles.
    @MainActor
    private func controlTaskState(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        guard let id = params["id"]?.nilIfBlank else { return err("state requires a task id") }
        guard let task = viewModel.tasks.first(where: { $0.id == id }) else {
            return err("task not found: \(id)")
        }
        let state = viewModel.taskAgentState(task)
        return ok([
            "id": task.id,
            "state": state.rawValue,
            "running": state == .running,
        ])
    }

    /// `restart <task-id>` — kills the task's agent and relaunches it in place, resuming its session.
    @MainActor
    private func controlRestart(params: [String: String], viewModel: BoardViewModel) -> [String: Any] {
        guard let id = params["id"]?.nilIfBlank else { return err("restart requires a task id") }
        guard viewModel.tasks.contains(where: { $0.id == id }) else { return err("task not found: \(id)") }
        guard let runtime = terminalRuntime else { return err("terminal backend not ready") }
        let restarted = TerminalRestart.restart(
            taskID: id,
            surfaceID: params["surface"]?.nilIfBlank,
            viewModel: viewModel,
            runtime: runtime,
            artifactDirectory: launchOptions?.artifactDirectory
        )
        guard restarted else {
            return err("no agent surface to restart for \(id) — open the task first")
        }
        return ok(["restarted": id])
    }

    @MainActor
    private func controlStatus(viewModel: BoardViewModel) -> [String: Any] {
        let running = viewModel.tasks.filter { viewModel.taskIsRunning($0) }.map(\.id)
        return ok([
            "selectedProject": viewModel.selectedProjectID.map { $0 as Any } ?? NSNull(),
            "selectedTask": viewModel.selectedTaskID.map { $0 as Any } ?? NSNull(),
            "running": running,
            "taskCount": viewModel.tasks.count,
            "projectCount": viewModel.projects.count,
            "notifications": SystemNotificationPresenter.shared.authorizationState.description,
        ])
    }

    private var appVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Brings Balagan forward and selects the task + surface behind a clicked notification.
    @MainActor
    func focusSurfaceFromNotification(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        guard let viewModel, let task = viewModel.tasks.first(where: { $0.id == taskID }) else { return }
        window?.makeKeyAndOrderFront(nil)
        viewModel.select(task: task)
        viewModel.select(surfaceID: surfaceID, forTaskID: taskID)
    }

    /// Symlinks the bundled `balagan` CLI onto PATH so it's usable right after launch (cmux-style).
    /// Best-effort and idempotent. Only runs from a packaged `.app` — never the dev/.build binary,
    /// which would hijack the user's PATH during tests. Prefers the first writable PATH directory and
    /// never overwrites a real file of the same name.
    func installControlCLISymlinkIfPossible(options: LaunchOptions) {
        guard options.uiTestMode == false else { return }
        guard Bundle.main.bundleURL.pathExtension == "app", let executableURL = Bundle.main.executableURL else {
            return
        }
        let fileManager = FileManager.default
        let cliURL = executableURL.deletingLastPathComponent().appendingPathComponent("balagan")
        guard fileManager.isExecutableFile(atPath: cliURL.path) else { return }

        let localBin = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let candidates: [String]
        let createIfMissing: Set<String>
        if let override = options.controlCLILinkDirectory {
            candidates = [override]
            createIfMissing = [override]
        } else {
            // /usr/local/bin and /opt/homebrew/bin are on the default macOS PATH; ~/.local/bin is the
            // always-user-writable fallback (the user may need to add it to PATH).
            candidates = ["/usr/local/bin", "/opt/homebrew/bin", localBin]
            createIfMissing = [localBin]
        }

        for directory in candidates {
            if createIfMissing.contains(directory), fileManager.fileExists(atPath: directory) == false {
                try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            switch ControlCLIInstaller.installLink(cliPath: cliURL.path, directory: directory) {
            case .installed:
                NSLog("Balagan: linked `balagan` CLI into \(directory)")
                return
            case .alreadyCurrent:
                return
            case .directoryMissing, .notWritable, .realFilePresent, .failed:
                continue
            }
        }
        NSLog("Balagan: could not auto-install the `balagan` CLI on PATH (no writable directory found).")
    }
}
