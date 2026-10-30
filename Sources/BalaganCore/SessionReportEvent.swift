import Foundation
import Darwin

public enum SessionReportEventKind: String, Codable, Equatable, Hashable, Sendable {
    case sessionStart = "session-start"
    case sessionEnd = "session-end"
    case cwd
    case status
    /// Agent working-state update (running / idle / needs-input), from the agent's hooks (see
    /// `AgentHookEvent`). Carried in `lifecycle`, with the tool it concerns in `toolName`.
    case lifecycle
}

public struct SessionReportEvent: Codable, Equatable, Sendable {
    public var event: SessionReportEventKind
    public var taskID: Task.ID
    public var workspaceID: Workspace.ID
    public var surfaceID: Surface.ID
    public var agentName: String?
    public var sessionID: String?
    public var pid: Int32?
    public var executablePath: String?
    public var argv: [String]
    public var cwd: String?
    /// Path to the agent's on-disk session transcript (Claude hook `transcript_path`, Codex rollout
    /// file). Feeds the reader-mode/speak pipeline via `ResumeBinding.transcriptPath`.
    public var transcriptPath: String?
    public var status: String?
    public var command: String?
    public var lifecycle: String?
    /// The tool a `.lifecycle` report concerns (the hook payload's `tool_name`) — e.g. the tool a
    /// needs-input permission request is about. Optional and additive: older senders omit it.
    public var toolName: String?
    public var environment: [String: String]
    public var reportedAt: Date?

    public init(
        event: SessionReportEventKind,
        taskID: Task.ID,
        workspaceID: Workspace.ID,
        surfaceID: Surface.ID,
        agentName: String? = nil,
        sessionID: String? = nil,
        pid: Int32? = nil,
        executablePath: String? = nil,
        argv: [String] = [],
        cwd: String? = nil,
        transcriptPath: String? = nil,
        status: String? = nil,
        command: String? = nil,
        lifecycle: String? = nil,
        toolName: String? = nil,
        environment: [String: String] = [:],
        reportedAt: Date? = nil
    ) {
        self.event = event
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.agentName = agentName
        self.sessionID = sessionID
        self.pid = pid
        self.executablePath = executablePath
        self.argv = argv
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.status = status
        self.command = command
        self.lifecycle = lifecycle
        self.toolName = toolName
        self.environment = environment
        self.reportedAt = reportedAt
    }
}

public enum SessionReportEventParser {
    public static func parseLine(_ line: String) throws -> SessionReportEvent {
        guard let data = line.data(using: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> SessionReportEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionReportEvent.self, from: data)
    }

    public static func encodeLine(_ event: SessionReportEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0a)
        return data
    }
}

public enum SessionReportEventSocketSender {
    public static func send(event: SessionReportEvent, socketPath: String) throws {
        let fd: Int32
        switch UnixSocketHelpers.connectedClient(path: socketPath) {
        case .success(let connected): fd = connected
        case .failure(.pathTooLong): throw SessionReportEventSocketError.pathTooLong(socketPath)
        case .failure(.socket(let code)): throw SessionReportEventSocketError.socketFailed(code)
        case .failure(.connect(let code)):
            throw SessionReportEventSocketError.connectFailed(socketPath: socketPath, errno: code)
        }
        defer { Darwin.close(fd) }

        if let code = UnixSocketHelpers.writeAll(try SessionReportEventParser.encodeLine(event), to: fd) {
            throw SessionReportEventSocketError.writeFailed(socketPath: socketPath, errno: code)
        }
    }
}

public enum SessionReportEventSocketError: Error, CustomStringConvertible, Equatable {
    case socketFailed(Int32)
    case pathTooLong(String)
    case connectFailed(socketPath: String, errno: Int32)
    case writeFailed(socketPath: String, errno: Int32)

    public var description: String {
        switch self {
        case let .socketFailed(errno):
            return "socket(AF_UNIX) failed with errno \(errno)"
        case let .pathTooLong(socketPath):
            return "socket path is too long: \(socketPath)"
        case let .connectFailed(socketPath, errno):
            return "connect(\(socketPath)) failed with errno \(errno)"
        case let .writeFailed(socketPath, errno):
            return "write(\(socketPath)) failed with errno \(errno)"
        }
    }
}

public struct TerminalRuntimeLaunchContext: Equatable, Sendable {
    public var taskID: Task.ID
    public var workspaceID: Workspace.ID
    public var surfaceID: Surface.ID
    public var socketPath: String?

    public init(
        taskID: Task.ID,
        workspaceID: Workspace.ID,
        surfaceID: Surface.ID,
        socketPath: String? = nil
    ) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.socketPath = socketPath
    }

    public var environment: [String: String] {
        var result = [
            "BALAGAN_TASK_ID": taskID,
            "BALAGAN_WORKSPACE_ID": workspaceID,
            "BALAGAN_SURFACE_ID": surfaceID,
        ]
        if let socketPath, socketPath.isEmpty == false {
            result["BALAGAN_SOCKET_PATH"] = socketPath
        }
        return result
    }

    public func applying(to command: PtyCommand) -> PtyCommand {
        PtyCommand(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment.merging(environment) { _, runtime in runtime },
            workingDirectory: command.workingDirectory
        )
    }
}
