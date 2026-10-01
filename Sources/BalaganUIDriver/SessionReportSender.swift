import Darwin
import Foundation
import BalaganCore

enum SessionReportSender {
    static func run(arguments: [String]) throws {
        let options = try SessionReportSenderOptions.parse(arguments)
        let event = SessionReportEvent(
            event: .sessionStart,
            taskID: options.taskID,
            workspaceID: options.workspaceID,
            surfaceID: options.surfaceID,
            agentName: options.agentName,
            sessionID: options.sessionID,
            pid: getpid(),
            executablePath: options.executablePath,
            argv: options.argv,
            cwd: options.cwd,
            status: options.status,
            command: options.command,
            environment: ProcessInfo.processInfo.environment
        )
        try send(event: event, socketPath: options.socketPath)
        if let artifactDirectory = options.artifactDirectory {
            try writeArtifact(event: event, socketPath: options.socketPath, artifactDirectory: artifactDirectory)
        }
    }

    private static func send(event: SessionReportEvent, socketPath: String) throws {
        do {
            try SessionReportEventSocketSender.send(event: event, socketPath: socketPath)
        } catch let error as SessionReportEventSocketError {
            throw DriverError.invalidArguments(error.description)
        }
    }

    private static func writeArtifact(
        event: SessionReportEvent,
        socketPath: String,
        artifactDirectory: URL
    ) throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "socketPath": socketPath,
            "event": event.event.rawValue,
            "taskID": event.taskID,
            "workspaceID": event.workspaceID,
            "surfaceID": event.surfaceID,
            "agentName": event.agentName.map { $0 as Any } ?? NSNull(),
            "sessionID": event.sessionID.map { $0 as Any } ?? NSNull(),
            "command": event.command.map { $0 as Any } ?? NSNull(),
            "status": event.status.map { $0 as Any } ?? NSNull(),
        ]
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifactDirectory.appendingPathComponent("session-report-sent.json"), options: .atomic)
    }
}

private struct SessionReportSenderOptions {
    var socketPath: String
    var artifactDirectory: URL?
    var taskID: String
    var workspaceID: String
    var surfaceID: String
    var agentName: String
    var sessionID: String
    var cwd: String?
    var status: String?
    var command: String?
    var executablePath: String?
    var argv: [String]

    static func parse(_ arguments: [String]) throws -> SessionReportSenderOptions {
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option),
                  arguments.indices.contains(index + 1)
            else {
                return nil
            }
            return arguments[index + 1]
        }

        let socketPath = value(after: "--socket-path")
            ?? ProcessInfo.processInfo.environment["BALAGAN_SOCKET_PATH"]
        guard let socketPath, socketPath.isEmpty == false else {
            throw DriverError.invalidArguments("--socket-path or BALAGAN_SOCKET_PATH is required")
        }
        guard let taskID = value(after: "--task-id"), taskID.isEmpty == false else {
            throw DriverError.invalidArguments("--task-id is required")
        }
        guard let workspaceID = value(after: "--workspace-id"), workspaceID.isEmpty == false else {
            throw DriverError.invalidArguments("--workspace-id is required")
        }
        guard let surfaceID = value(after: "--surface-id"), surfaceID.isEmpty == false else {
            throw DriverError.invalidArguments("--surface-id is required")
        }

        let artifactDirectory = value(after: "--artifact-dir").map { URL(fileURLWithPath: $0) }
        let agentName = value(after: "--agent-name") ?? "codex"
        let sessionID = value(after: "--session-id") ?? "fake-session-123"
        let command = value(after: "--command") ?? "\(agentName) resume \(sessionID)"
        let argv = value(after: "--argv")?.split(separator: "\u{1f}").map(String.init)
            ?? [agentName]

        return SessionReportSenderOptions(
            socketPath: socketPath,
            artifactDirectory: artifactDirectory,
            taskID: taskID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentName: agentName,
            sessionID: sessionID,
            cwd: value(after: "--cwd"),
            status: value(after: "--status") ?? "running",
            command: command,
            executablePath: value(after: "--executable-path"),
            argv: argv
        )
    }
}
