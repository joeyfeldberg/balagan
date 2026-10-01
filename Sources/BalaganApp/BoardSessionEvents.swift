import Foundation
import BalaganCore

/// Applies agent session-report events (start / cwd / status / end) reported over the local socket
/// onto the matching surface's resume binding, plan, cwd, and status log.
/// Extracted from `BoardViewModel`.
extension BoardViewModel {
    func applyReportedSessionCapture(_ event: SessionReportEvent) -> SessionReportApplyResult {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == event.taskID }) else {
            return SessionReportApplyResult(status: "ignored", message: "task mismatch", resumeCommand: nil)
        }

        let workspaceID = tasks[taskIndex].workspace.id
        guard workspaceID == event.workspaceID else {
            return SessionReportApplyResult(status: "ignored", message: "workspace mismatch", resumeCommand: nil)
        }

        guard let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == event.surfaceID }) else {
            return SessionReportApplyResult(status: "ignored", message: "surface mismatch", resumeCommand: nil)
        }

        switch event.event {
        case .sessionStart:
            return applySessionStartReport(event, taskIndex: taskIndex, surfaceIndex: surfaceIndex)
        case .cwd:
            if let cwd = event.cwd?.nilIfBlank {
                tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd = cwd
            }
            tasks[taskIndex].workspace.lastOpenedAt = Date()
            tasks[taskIndex].updatedAt = Date()
            return SessionReportApplyResult(status: "applied", message: "cwd updated", resumeCommand: nil)
        case .status:
            if let status = event.status?.nilIfBlank {
                appendSessionStatus(taskIndex: taskIndex, surfaceIndex: surfaceIndex, status: status)
            }
            tasks[taskIndex].workspace.lastOpenedAt = Date()
            tasks[taskIndex].updatedAt = Date()
            return SessionReportApplyResult(status: "applied", message: "status updated", resumeCommand: nil)
        case .lifecycle:
            // Runtime-only working-state (drives the card spinner); not persisted, so don't touch updatedAt.
            // Ignore for a slept task: its agents were terminated, and the reconciler skips hibernated
            // tasks, so a late report would strand a running state with nothing to clear it.
            guard hibernatedTaskIDs.contains(event.taskID) == false else {
                return SessionReportApplyResult(status: "ignored", message: "task hibernated", resumeCommand: nil)
            }
            setSurfaceLifecycle(event.lifecycle, taskID: event.taskID, surfaceID: event.surfaceID)
            return SessionReportApplyResult(status: "applied", message: "lifecycle \(event.lifecycle ?? "?")", resumeCommand: nil)
        case .sessionEnd:
            if var binding = tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding {
                let now = event.reportedAt ?? Date()
                binding.wasRunning = false
                binding.captureUpdatedAt = now
                binding.updatedAt = now
                tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding = binding
            }
            tasks[taskIndex].workspace.lastOpenedAt = Date()
            tasks[taskIndex].updatedAt = Date()
            return SessionReportApplyResult(status: "applied", message: "session ended", resumeCommand: nil)
        }
    }

    private func applySessionStartReport(
        _ event: SessionReportEvent,
        taskIndex: Int,
        surfaceIndex: Int
    ) -> SessionReportApplyResult {
        guard let agentName = event.agentName?.nilIfBlank else {
            return SessionReportApplyResult(status: "ignored", message: "missing agentName", resumeCommand: nil)
        }
        let key = hostKey(event.taskID, event.surfaceID)
        guard let sessionID = event.sessionID?.nilIfBlank else {
            // The agent started but its session isn't known yet: the tab is an agent tab from now on,
            // and the binding follows when the session is reported.
            runningAgents[key] = RunningAgent(name: agentName, pid: event.pid)
            return SessionReportApplyResult(status: "applied", message: "agent started (session pending)", resumeCommand: nil)
        }
        runningAgents[key] = nil

        let now = event.reportedAt ?? Date()
        let command = event.command?.nilIfBlank ?? "\(agentName) resume \(sessionID)"
        let cwd = event.cwd?.nilIfBlank
        let sanitizedEnvironment = EnvironmentSanitizer().sanitize(event.environment)
        // Claude reports session start twice (wrapper pre-exec without the transcript, then the
        // SessionStart hook with it) — keep a known transcript for the same session instead of
        // wiping it when an event without one arrives.
        let existingBinding = tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding
        let transcriptPath = event.transcriptPath?.nilIfBlank
            ?? (existingBinding?.sessionID == sessionID ? existingBinding?.transcriptPath : nil)
        let binding = ResumeBinding(
            id: "resume-\(event.surfaceID)",
            taskID: event.taskID,
            workspaceID: event.workspaceID,
            surfaceID: event.surfaceID,
            kind: .agent,
            agentName: agentName,
            sessionID: sessionID,
            command: command,
            trust: .trusted,
            source: .agentHook,
            pid: event.pid,
            executablePath: event.executablePath?.nilIfBlank,
            argv: event.argv,
            cwd: cwd,
            capturedAt: now,
            captureUpdatedAt: now,
            wasRunning: true,
            isRestorable: true,
            isStale: false,
            autoResume: true,
            transcriptPath: transcriptPath,
            sanitizedEnvironment: sanitizedEnvironment,
            createdAt: now,
            updatedAt: now
        )

        tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding = binding
        if let cwd {
            tasks[taskIndex].workspace.surfaces[surfaceIndex].cwd = cwd
        }
        if let status = event.status?.nilIfBlank {
            appendSessionStatus(taskIndex: taskIndex, surfaceIndex: surfaceIndex, status: status)
        }
        tasks[taskIndex].workspace.lastOpenedAt = now
        tasks[taskIndex].updatedAt = now

        return SessionReportApplyResult(
            status: "applied",
            message: "session capture applied",
            resumeCommand: tasks[taskIndex].workspace.surfaces[surfaceIndex].resumePlan(taskID: event.taskID)?.displayCommand
        )
    }

    private func appendSessionStatus(taskIndex: Int, surfaceIndex: Int, status: String) {
        let line = "session status: \(status)"
        if tasks[taskIndex].workspace.surfaces[surfaceIndex].output.last != line {
            tasks[taskIndex].workspace.surfaces[surfaceIndex].output.append(line)
        }
    }
}
