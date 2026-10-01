import Foundation

public enum TerminalLaunchSource: String, Codable, Equatable, Hashable, Sendable {
    case startupCommand
    case startupShell
    case trustedResume
}

public struct TerminalLaunchRequest: Equatable, Sendable {
    public var surfaceID: Surface.ID
    public var source: TerminalLaunchSource
    public var command: PtyCommand
    public var displayCommand: String

    public init(
        surfaceID: Surface.ID,
        source: TerminalLaunchSource,
        command: PtyCommand,
        displayCommand: String
    ) {
        self.surfaceID = surfaceID
        self.source = source
        self.command = command
        self.displayCommand = displayCommand
    }
}

public enum TerminalLaunchPlanner {
    public static func launchRequest(
        for surface: Surface,
        taskID: Task.ID,
        processPreference: ResumeLaunchProcessPreference = .allowProcessLaunch
    ) -> TerminalLaunchRequest? {
        switch ResumeLaunchPolicy.action(for: surface, taskID: taskID, processPreference: processPreference) {
        case .autoResume(let command):
            return terminalLaunchRequest(from: command, source: .trustedResume)
        case .startupCommand(let command):
            return terminalLaunchRequest(from: command, source: .startupCommand)
        case .idle, .restoredOnly, .needsConfirmation, .startupShell:
            return nil
        }
    }

    private static func terminalLaunchRequest(
        from command: ResumeLaunchCommand,
        source: TerminalLaunchSource
    ) -> TerminalLaunchRequest? {
        guard let ptyCommand = command.ptyCommand else {
            return nil
        }

        return TerminalLaunchRequest(
            surfaceID: command.surfaceID,
            source: source,
            command: ptyCommand,
            displayCommand: command.displayCommand
        )
    }
}

public struct TerminalTranscriptSnapshot: Codable, Equatable, Sendable {
    public var surfaceID: Surface.ID
    public var title: String
    public var cwd: String
    public var lines: [String]
    public var exitStatus: Int32?

    public init(
        surfaceID: Surface.ID,
        title: String,
        cwd: String,
        lines: [String],
        exitStatus: Int32? = nil
    ) {
        self.surfaceID = surfaceID
        self.title = title
        self.cwd = cwd
        self.lines = lines
        self.exitStatus = exitStatus
    }

    public var scrollbackSnapshot: String {
        lines.joined(separator: "\n")
    }
}

public protocol TerminalEmulator: Sendable {
    mutating func resize(columns: UInt16, rows: UInt16)
    mutating func feed(_ data: Data)
    func snapshot(surface: Surface, exitStatus: Int32?) -> TerminalTranscriptSnapshot
}

public struct PlainTextTerminalEmulator: TerminalEmulator {
    public private(set) var columns: UInt16
    public private(set) var rows: UInt16
    public var maxLines: Int

    private var buffer = ""

    public init(columns: UInt16 = 120, rows: UInt16 = 40, maxLines: Int = 2_000) {
        self.columns = columns
        self.rows = rows
        self.maxLines = maxLines
    }

    public mutating func resize(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    public mutating func feed(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
    }

    public func snapshot(surface: Surface, exitStatus: Int32?) -> TerminalTranscriptSnapshot {
        TerminalTranscriptSnapshot(
            surfaceID: surface.id,
            title: surface.title,
            cwd: surface.cwd,
            lines: normalizedLines(),
            exitStatus: exitStatus
        )
    }

    private func normalizedLines() -> [String] {
        let normalized = buffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard lines.count > maxLines else {
            return lines
        }

        return Array(lines.suffix(maxLines))
    }
}

public struct TerminalSurfaceRunResult: Equatable, Sendable {
    public var launchRequest: TerminalLaunchRequest
    public var transcript: TerminalTranscriptSnapshot
    public var updatedSurface: Surface

    public init(
        launchRequest: TerminalLaunchRequest,
        transcript: TerminalTranscriptSnapshot,
        updatedSurface: Surface
    ) {
        self.launchRequest = launchRequest
        self.transcript = transcript
        self.updatedSurface = updatedSurface
    }
}

public enum TerminalSurfaceSession {
    public static func run(
        surface: Surface,
        taskID: Task.ID,
        socketPath: String? = nil,
        windowSize: PtyWindowSize = PtyWindowSize(columns: 120, rows: 40),
        runner: any TerminalProcessRunning = LivePtyProcessRunner()
    ) throws -> TerminalSurfaceRunResult? {
        guard let launchRequest = TerminalLaunchPlanner.launchRequest(for: surface, taskID: taskID) else {
            return nil
        }

        let runtimeContext = TerminalRuntimeLaunchContext(
            taskID: taskID,
            workspaceID: surface.workspaceID,
            surfaceID: surface.id,
            socketPath: socketPath
        )
        let command = runtimeContext.applying(to: launchRequest.command)
        let result = try runner.run(command, windowSize: windowSize)
        var emulator = PlainTextTerminalEmulator(columns: windowSize.columns, rows: windowSize.rows)
        emulator.feed(result.output)

        let transcript = emulator.snapshot(surface: surface, exitStatus: result.exitStatus)
        var updatedSurface = surface
        updatedSurface.scrollbackSnapshot = transcript.scrollbackSnapshot

        return TerminalSurfaceRunResult(
            launchRequest: launchRequest,
            transcript: transcript,
            updatedSurface: updatedSurface
        )
    }
}
