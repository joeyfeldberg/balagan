import Foundation
import BalaganCore

/// On launch, tries to re-attach a resume binding to each Codex surface that lost one, by matching
/// the surface's cwd against locally persisted Codex sessions. Extracted from `BoardViewModel`.
extension BoardViewModel {
    func recoverPendingCodexSurfaces() {
        let environment = ProcessInfo.processInfo.environment
        let capture = CodexSessionCapture.fromEnvironment(environment)

        for taskIndex in tasks.indices {
            let taskID = tasks[taskIndex].id
            let workspaceID = tasks[taskIndex].workspace.id
            for surfaceIndex in tasks[taskIndex].workspace.surfaces.indices {
                let surface = tasks[taskIndex].workspace.surfaces[surfaceIndex]
                guard surface.resumeBinding == nil else {
                    continue
                }

                do {
                    switch try capture.recoverCodexResumeBinding(
                        surface: surface,
                        taskID: taskID,
                        workspaceID: workspaceID,
                        environment: environment,
                        legacyReferenceDate: tasks[taskIndex].updatedAt
                    ) {
                    case .recovered(let recoveredSurface):
                        tasks[taskIndex].workspace.surfaces[surfaceIndex].resumeBinding = recoveredSurface.resumeBinding
                        tasks[taskIndex].updatedAt = Date()
                        recoveredCodexSurfaceCount += 1
                    case .missing:
                        appendCodexRecoveryStatus(
                            taskIndex: taskIndex,
                            surfaceIndex: surfaceIndex,
                            status: "Codex recovery: no matching local Codex session found for cwd \(surface.cwd); checked persisted state and rollout files; fresh startup suppressed, so capture the session manually or start a new agent surface"
                        )
                    case .ambiguous(let sessionIDs):
                        appendCodexRecoveryStatus(
                            taskIndex: taskIndex,
                            surfaceIndex: surfaceIndex,
                            status: "Codex recovery: multiple matching Codex sessions found for cwd \(surface.cwd) (\(sessionIDs.joined(separator: ", "))); fresh startup suppressed, so choose a session manually before resuming"
                        )
                    case .notNeeded:
                        break
                    }
                } catch {
                    appendCodexRecoveryStatus(
                        taskIndex: taskIndex,
                        surfaceIndex: surfaceIndex,
                        status: "Codex recovery: local Codex state lookup failed (\(error.localizedDescription)); fresh startup suppressed, so capture the session manually or start a new agent surface"
                    )
                }
            }
        }
    }

    private func appendCodexRecoveryStatus(taskIndex: Int, surfaceIndex: Int, status: String) {
        let line = "session status: \(status)"
        if tasks[taskIndex].workspace.surfaces[surfaceIndex].output.last != line {
            tasks[taskIndex].workspace.surfaces[surfaceIndex].output.append(line)
        }
    }
}
