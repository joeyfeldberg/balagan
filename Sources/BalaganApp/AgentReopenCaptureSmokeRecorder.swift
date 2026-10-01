import Foundation
import BalaganCore

enum AgentReopenCaptureSmokeRecorder {
    private static let schemaVersion = 1
    private static let artifactName = "agent-reopen-capture-smoke.json"
    private static let taskID = "task-fake-terminal"

    /// A freshly created agent surface that launched successfully, carrying the state the later
    /// capture/restore steps need.
    private struct PreparedAgentSurface {
        let taskID: TaskItem.ID
        let surface: Surface
        let workspaceID: Workspace.ID
        let launchStartedAtMs: Int64
    }

    @MainActor
    static func capture(viewModel: BoardViewModel, socketPath: String, artifactDirectory: URL?) {
        guard let prepared = createAndRunAgentSurface(
            viewModel: viewModel,
            socketPath: socketPath,
            artifactDirectory: artifactDirectory
        ) else {
            return
        }

        guard let (capturedSurface, captureFallbackApplied) = resolveCapturedSurface(
            viewModel: viewModel,
            prepared: prepared,
            artifactDirectory: artifactDirectory
        ) else {
            return
        }

        writeRestoreArtifact(
            taskID: prepared.taskID,
            capturedSurface: capturedSurface,
            captureFallbackApplied: captureFallbackApplied,
            artifactDirectory: artifactDirectory
        )
    }

    /// Selects the target task, adds a new agent surface, and runs it once through the headless
    /// backend. Writes a failure artifact and returns nil if any step doesn't produce the surface.
    @MainActor
    private static func createAndRunAgentSurface(
        viewModel: BoardViewModel,
        socketPath: String,
        artifactDirectory: URL?
    ) -> PreparedAgentSurface? {
        guard let task = viewModel.tasks.first(where: { $0.id == taskID }) ?? viewModel.tasks.first else {
            write(status: "failed", message: "no task available", payload: [:], artifactDirectory: artifactDirectory)
            return nil
        }

        let launchStartedAtMs = Date().millisecondsSince1970
        let surfaceCount = task.workspace.surfaces.count
        viewModel.select(task: task)
        viewModel.createAgentSurface(taskID: task.id)

        guard let createdTask = viewModel.tasks.first(where: { $0.id == task.id }),
              let surface = createdTask.workspace.surfaces.last,
              createdTask.workspace.surfaces.count == surfaceCount + 1
        else {
            write(status: "failed", message: "agent surface was not created", payload: [:], artifactDirectory: artifactDirectory)
            return nil
        }

        let workspaceID = surface.workspaceID(taskID: createdTask.id)
        do {
            let result = try TerminalSurfaceSession.run(
                surface: surface,
                taskID: createdTask.id,
                socketPath: socketPath
            )
            if let result {
                viewModel.updateSurfaceState(
                    taskID: createdTask.id,
                    surfaceID: surface.id,
                    title: result.transcript.title,
                    cwd: result.transcript.cwd,
                    output: result.transcript.lines
                )
            }
        } catch {
            write(
                status: "failed",
                message: "agent launch failed: \(error)",
                payload: surfacePayload(taskID: createdTask.id, surface: surface),
                artifactDirectory: artifactDirectory
            )
            return nil
        }

        return PreparedAgentSurface(
            taskID: createdTask.id,
            surface: surface,
            workspaceID: workspaceID,
            launchStartedAtMs: launchStartedAtMs
        )
    }

    /// Waits for the agent's session-start report to bind the surface, falling back to the Codex
    /// capture probe. Writes a failure artifact (with diagnostics) and returns nil if nothing binds.
    @MainActor
    private static func resolveCapturedSurface(
        viewModel: BoardViewModel,
        prepared: PreparedAgentSurface,
        artifactDirectory: URL?
    ) -> (surface: Surface, fallbackApplied: Bool)? {
        var captureFallbackApplied = false
        let capturedSurface = waitForCapturedSurface(
            viewModel: viewModel,
            taskID: prepared.taskID,
            surfaceID: prepared.surface.id,
            timeout: 12
        ) ?? {
            captureFallbackApplied = true
            return applyCodexCaptureFallback(
                viewModel: viewModel,
                taskID: prepared.taskID,
                workspaceID: prepared.workspaceID,
                surface: prepared.surface,
                launchStartedAtMs: prepared.launchStartedAtMs
            )
        }()

        guard let capturedSurface else {
            var payload = surfacePayload(taskID: prepared.taskID, surface: prepared.surface)
            payload.merge(
                codexCaptureFallbackDiagnostics(surface: prepared.surface, launchStartedAtMs: prepared.launchStartedAtMs)
            ) { _, diagnostic in diagnostic }
            write(
                status: "failed",
                message: "session-start report was not captured before timeout",
                payload: payload,
                artifactDirectory: artifactDirectory
            )
            return nil
        }

        return (capturedSurface, captureFallbackApplied)
    }

    /// Records the restore-plan artifact: whether restore prefers the captured trusted resume binding.
    @MainActor
    private static func writeRestoreArtifact(
        taskID: TaskItem.ID,
        capturedSurface: Surface,
        captureFallbackApplied: Bool,
        artifactDirectory: URL?
    ) {
        let launchRequest = TerminalLaunchPlanner.launchRequest(
            for: capturedSurface,
            taskID: taskID
        )
        var payload = surfacePayload(taskID: taskID, surface: capturedSurface)
        payload["restoreLaunchSource"] = launchRequest?.source.rawValue as Any? ?? NSNull()
        payload["restoreCommand"] = launchRequest?.displayCommand as Any? ?? NSNull()
        payload["restoreArgv"] = launchRequest.map { [$0.command.executable] + $0.command.arguments } as Any? ?? NSNull()
        payload["captureFallbackApplied"] = captureFallbackApplied

        write(
            status: launchRequest?.source == .trustedResume ? "captured" : "failed",
            message: launchRequest?.source == .trustedResume
                ? "agent session captured and restore prefers resume binding"
                : "restore launch did not prefer trusted resume binding",
            payload: payload,
            artifactDirectory: artifactDirectory
        )
    }

    @MainActor
    static func recordObservedState(viewModel: BoardViewModel, artifactDirectory: URL?) {
        guard let task = viewModel.tasks.first(where: { $0.id == taskID }) ?? viewModel.tasks.first,
              let surface = task.workspace.surfaces.first(where: { $0.resumeBinding?.source == .agentHook })
        else {
            return
        }

        let launchRequest = TerminalLaunchPlanner.launchRequest(
            for: surface,
            taskID: task.id
        )
        var payload = surfacePayload(taskID: task.id, surface: surface)
        payload["restoreLaunchSource"] = launchRequest?.source.rawValue as Any? ?? NSNull()
        payload["restoreCommand"] = launchRequest?.displayCommand as Any? ?? NSNull()
        write(
            status: "observed",
            message: "observed persisted captured agent surface",
            payload: payload,
            artifactDirectory: artifactDirectory
        )
    }

    @MainActor
    private static func waitForCapturedSurface(
        viewModel: BoardViewModel,
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        timeout: TimeInterval
    ) -> Surface? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let task = viewModel.tasks.first(where: { $0.id == taskID }),
               let surface = task.workspace.surfaces.first(where: { $0.id == surfaceID }),
               surface.resumeBinding?.source == .agentHook,
               surface.resumeBinding?.sessionID?.nilIfBlank != nil {
                return surface
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        return nil
    }

    @MainActor
    private static func applyCodexCaptureFallback(
        viewModel: BoardViewModel,
        taskID: TaskItem.ID,
        workspaceID: Workspace.ID,
        surface: Surface,
        launchStartedAtMs: Int64
    ) -> Surface? {
        guard surface.startupCommand?.contains("codex") == true else {
            return nil
        }

        let environment = ProcessInfo.processInfo.environment
        let capture = CodexSessionCapture.fromEnvironment(environment)

        guard case .captured(let sessionID) = try? capture.capture(cwd: surface.cwd, startMs: launchStartedAtMs) else {
            return nil
        }

        let event = SessionReportEvent(
            event: .sessionStart,
            taskID: taskID,
            workspaceID: workspaceID,
            surfaceID: surface.id,
            agentName: "codex",
            sessionID: sessionID,
            argv: ["codex"],
            cwd: surface.cwd,
            command: "codex resume \(sessionID)",
            environment: environment,
            reportedAt: Date()
        )
        _ = viewModel.applyReportedSessionCapture(event)

        return viewModel.tasks
            .first { $0.id == taskID }?
            .workspace
            .surfaces
            .first { $0.id == surface.id && $0.resumeBinding?.sessionID == sessionID }
    }

    private static func codexCaptureFallbackDiagnostics(
        surface: Surface,
        launchStartedAtMs: Int64
    ) -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let captureHome = environment["BALAGAN_CODEX_CAPTURE_HOME"].map(URL.init(fileURLWithPath:))
        let capture = CodexSessionCapture.fromEnvironment(environment)
        let resultDescription: String
        do {
            resultDescription = "\(try capture.capture(cwd: surface.cwd, startMs: launchStartedAtMs))"
        } catch {
            resultDescription = "error: \(error)"
        }
        return [
            "fallbackCaptureHome": captureHome?.path as Any? ?? NSNull(),
            "fallbackStateDatabase": capture.stateDatabaseURL.path,
            "fallbackCwd": surface.cwd,
            "fallbackStartMs": launchStartedAtMs,
            "fallbackStartSkewAllowanceMs": capture.startSkewAllowanceMs,
            "fallbackResult": resultDescription,
        ]
    }

    private static func surfacePayload(taskID: TaskItem.ID, surface: Surface) -> [String: Any] {
        [
            "taskID": taskID,
            "surfaceID": surface.id,
            "startupCommand": surface.startupCommand as Any? ?? NSNull(),
            "bindingSource": surface.resumeBinding?.source.rawValue as Any? ?? NSNull(),
            "agentName": surface.resumeBinding?.agentName as Any? ?? NSNull(),
            "sessionID": surface.resumeBinding?.sessionID as Any? ?? NSNull(),
            "autoResume": surface.resumeBinding?.autoResume as Any? ?? NSNull(),
            "trust": surface.resumeBinding?.trust.rawValue as Any? ?? NSNull(),
            "isRestorable": surface.resumeBinding?.isRestorable as Any? ?? NSNull(),
            "isStale": surface.resumeBinding?.isStale as Any? ?? NSNull(),
        ]
    }

    private static func write(status: String, message: String, payload: [String: Any], artifactDirectory: URL?) {
        guard let artifactDirectory else {
            return
        }

        var data = payload
        data["schemaVersion"] = schemaVersion
        data["status"] = status
        data["message"] = message
        data["recordedAt"] = ISO8601DateFormatter().string(from: Date())

        ArtifactWriter.writeJSON(
            data,
            to: artifactDirectory,
            as: artifactName,
            errorLog: "agent-reopen-capture-smoke-error.log",
            failureMessage: "Failed to record agent reopen capture smoke artifact"
        )
    }
}
