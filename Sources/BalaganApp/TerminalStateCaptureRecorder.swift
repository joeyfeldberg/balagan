import Foundation
import BalaganCore

enum TerminalStateCaptureRecorder {
    private static let schemaVersion = 1
    private static let artifactName = "terminal-state-capture.json"

    static func capture(viewModel: BoardViewModel, socketPath: String?, artifactDirectory: URL?) {
        var records: [[String: Any]] = []

        for task in viewModel.tasks {
            for surface in task.workspace.surfaces {
                records.append(captureSurface(
                    viewModel: viewModel,
                    task: task,
                    surface: surface,
                    socketPath: socketPath
                ))
            }
        }

        write(
            phase: "captured",
            dataSource: viewModel.dataSource,
            records: records,
            artifactDirectory: artifactDirectory
        )
    }

    /// Runs one surface through the headless backend, updating its live state on success, and returns
    /// the record describing the outcome (skipped / captured / failed).
    private static func captureSurface(
        viewModel: BoardViewModel,
        task: TaskItem,
        surface: Surface,
        socketPath: String?
    ) -> [String: Any] {
        let coreSurface = surface

        do {
            guard let result = try TerminalSurfaceSession.run(
                surface: coreSurface,
                taskID: task.id,
                socketPath: socketPath
            ) else {
                return record(
                    taskID: task.id,
                    surfaceID: surface.id,
                    title: surface.title,
                    cwd: surface.cwd,
                    status: "skipped",
                    command: nil,
                    exitStatus: nil,
                    lines: surface.output,
                    message: "surface has no startup command or trusted resume binding"
                )
            }

            let lines = result.transcript.lines
            viewModel.updateSurfaceState(
                taskID: task.id,
                surfaceID: surface.id,
                title: result.transcript.title,
                cwd: result.transcript.cwd,
                output: lines
            )
            return record(
                taskID: task.id,
                surfaceID: surface.id,
                title: result.transcript.title,
                cwd: result.transcript.cwd,
                status: "captured",
                command: result.launchRequest.displayCommand,
                exitStatus: result.transcript.exitStatus,
                lines: lines,
                message: nil
            )
        } catch {
            return record(
                taskID: task.id,
                surfaceID: surface.id,
                title: surface.title,
                cwd: surface.cwd,
                status: "failed",
                command: surface.startupCommand,
                exitStatus: nil,
                lines: surface.output,
                message: String(describing: error)
            )
        }
    }

    static func recordObservedState(viewModel: BoardViewModel, artifactDirectory: URL?) {
        let records = viewModel.tasks.flatMap { task in
            task.workspace.surfaces.map { surface in
                record(
                    taskID: task.id,
                    surfaceID: surface.id,
                    title: surface.title,
                    cwd: surface.cwd,
                    status: "observed",
                    command: surface.startupCommand,
                    exitStatus: nil,
                    lines: surface.output,
                    message: nil
                )
            }
        }

        guard records.contains(where: { record in
            guard let lines = record["lines"] as? [String] else {
                return false
            }
            return lines.contains { $0.contains("BALAGAN_TERMINAL_STATE_CAPTURE") }
        }) else {
            return
        }

        write(
            phase: "observed",
            dataSource: viewModel.dataSource,
            records: records,
            artifactDirectory: artifactDirectory
        )
    }

    private static func record(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        title: String,
        cwd: String,
        status: String,
        command: String?,
        exitStatus: Int32?,
        lines: [String],
        message: String?
    ) -> [String: Any] {
        [
            "taskId": taskID,
            "surfaceId": surfaceID,
            "title": title,
            "cwd": cwd,
            "status": status,
            "command": command as Any? ?? NSNull(),
            "exitStatus": exitStatus as Any? ?? NSNull(),
            "lines": lines,
            "message": message as Any? ?? NSNull(),
        ]
    }

    private static func write(
        phase: String,
        dataSource: String,
        records: [[String: Any]],
        artifactDirectory: URL?
    ) {
        guard let artifactDirectory else {
            return
        }

        let capturedCount = records.filter { ($0["status"] as? String) == "captured" }.count
        let payload: [String: Any] = [
            "schemaVersion": schemaVersion,
            "phase": phase,
            "dataSource": dataSource,
            "capturedCount": capturedCount,
            "records": records,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: artifactName,
            errorLog: "terminal-state-capture-error.log",
            failureMessage: "Failed to record terminal state capture artifact"
        )
    }
}
