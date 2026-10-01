import Darwin
import Foundation

/// What a single `balagan-agent hook <event>` invocation ended up doing.
///
/// The whole point of the hook log is to tell "the hook never fired" apart from "the hook fired and
/// the send failed" — every early return in the wrapper maps onto one of these.
public enum AgentHookLogOutcome: Equatable, Sendable {
    /// The report reached the app's session-report socket.
    case sent
    /// The socket send threw; the payload is the errno text (never the event body).
    case sendFailed(String)
    /// The payload carried `agent_id`, so it was a subagent's hook (never drives the surface).
    case droppedSubagent
    /// `AgentHookEvent.report(payload:)` returned nil (e.g. an unclassified `Notification`).
    case droppedNoMapping
    /// One of the four `BALAGAN_*` routing variables was missing or blank.
    case droppedMissingEnv
    /// A `session-start` report with no session id in the payload.
    case droppedNoSessionID

    public var text: String {
        switch self {
        case .sent:
            return "sent"
        case let .sendFailed(reason):
            return "send-failed: \(reason)"
        case .droppedSubagent:
            return "dropped: subagent"
        case .droppedNoMapping:
            return "dropped: no-mapping"
        case .droppedMissingEnv:
            return "dropped: missing-env"
        case .droppedNoSessionID:
            return "dropped: no-session-id"
        }
    }

    /// Describes a failed send in errno terms (`connect: Connection refused`) rather than dumping a
    /// Swift error, so the log stays one short line per hook.
    public static func sendFailure(_ error: Error) -> AgentHookLogOutcome {
        guard let socketError = error as? SessionReportEventSocketError else {
            return .sendFailed(AgentHookLogEntry.sanitize(String(describing: error)))
        }
        switch socketError {
        case let .socketFailed(code):
            return .sendFailed("socket: \(errnoText(code))")
        case .pathTooLong:
            return .sendFailed("socket path too long")
        case let .connectFailed(_, code):
            return .sendFailed("connect: \(errnoText(code))")
        case let .writeFailed(_, code):
            return .sendFailed("write: \(errnoText(code))")
        }
    }

    private static func errnoText(_ code: Int32) -> String {
        guard let text = strerror(code) else {
            return "errno \(code)"
        }
        return "\(String(cString: text)) (errno \(code))"
    }
}

/// One line of `~/.balagan/agent-hooks.log`: what fired, where it was routed, and what happened.
///
/// Deliberately carries **no** payload body — a hook payload contains the user's prompt and tool
/// input. Only the hook name, the derived lifecycle, the routing ids, the tool name, and the outcome
/// are ever written.
public struct AgentHookLogEntry: Equatable, Sendable {
    public var timestamp: Date
    /// The wrapper's `hook <event>` argument (an `AgentHookEvent` raw value), or `launch` for the
    /// pre-exec session-start report the wrapper sends before `exec`ing the agent.
    public var event: String
    public var lifecycle: String?
    public var taskID: String?
    public var surfaceID: String?
    public var toolName: String?
    public var outcome: AgentHookLogOutcome

    public init(
        timestamp: Date = Date(),
        event: String,
        lifecycle: String? = nil,
        taskID: String? = nil,
        surfaceID: String? = nil,
        toolName: String? = nil,
        outcome: AgentHookLogOutcome
    ) {
        self.timestamp = timestamp
        self.event = event
        self.lifecycle = lifecycle
        self.taskID = taskID
        self.surfaceID = surfaceID
        self.toolName = toolName
        self.outcome = outcome
    }

    /// The formatted log line, without a trailing newline. Space-separated `key=value` so it stays
    /// greppable (`grep 'outcome=send-failed'`); absent fields read `-`.
    public var line: String {
        let fields = [
            "event=\(Self.sanitize(event))",
            "lifecycle=\(Self.sanitize(lifecycle))",
            "task=\(Self.sanitize(taskID))",
            "surface=\(Self.sanitize(surfaceID))",
            "tool=\(Self.sanitize(toolName))",
            "outcome=\(outcome.text)",
        ]
        return ([AgentHookLog.timestampText(timestamp)] + fields).joined(separator: " ")
    }

    /// Keeps a value on one line and bounded: whitespace collapses to `_`, blank becomes `-`.
    static func sanitize(_ value: String?) -> String {
        guard let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "-"
        }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: "_")
        return String(collapsed.prefix(120))
    }
}

/// The wrapper's hook log: where it lives, when it rotates, and how a line is appended.
///
/// Everything except `append` is pure so the format and the rotation rule are unit-tested; `append`
/// is the thin best-effort I/O around them (a hook must never fail because logging did).
public enum AgentHookLog {
    /// Overrides the log path. `off` (case-insensitive) disables logging entirely.
    public static let environmentKey = "BALAGAN_HOOK_LOG"
    public static let disabledValue = "off"
    /// Rotate to `<path>.1` once the file would grow past this. Hook lines are ~120 bytes, so this is
    /// several thousand hooks of history — plenty to debug a session, small enough to never matter.
    public static let maximumBytes = 1_048_576

    /// ISO-8601 UTC with milliseconds, so hooks fired within the same second still read in order.
    /// Built per call — `ISO8601DateFormatter` isn't `Sendable`, so it can't be a shared global under
    /// Swift 6, and the wrapper writes one line per process anyway.
    static func timestampText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// The log path, or nil when logging is switched off. Defaults to `~/.balagan/agent-hooks.log`
    /// — the same directory as the control socket, so all of Balagan's local state is in one place.
    public static func resolvePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            if override.lowercased() == disabledValue {
                return nil
            }
            return override
        }
        return homeDirectory + "/.balagan/agent-hooks.log"
    }

    /// Whether appending `appendingByteCount` bytes to a file of `currentByteCount` should rotate first.
    public static func shouldRotate(currentByteCount: Int, appendingByteCount: Int) -> Bool {
        currentByteCount + appendingByteCount > maximumBytes
    }

    /// The path a rotated log is moved to (one generation; the previous `.1` is replaced).
    public static func rotatedPath(for path: String) -> String {
        path + ".1"
    }

    /// Appends one entry, rotating first if the file would exceed `maximumBytes`. Best-effort and
    /// silent: a hook must exit 0 with clean stdout whatever happens here.
    public static func append(
        _ entry: AgentHookLogEntry,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        guard let path = resolvePath(environment: environment, homeDirectory: homeDirectory) else {
            return
        }
        append(entry, toPath: path)
    }

    /// Appends to an explicit path (the seam the unit tests drive).
    public static func append(_ entry: AgentHookLogEntry, toPath path: String) {
        let data = Data((entry.line + "\n").utf8)
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let currentByteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if shouldRotate(currentByteCount: currentByteCount, appendingByteCount: data.count) {
            let rotated = rotatedPath(for: path)
            try? fileManager.removeItem(atPath: rotated)
            try? fileManager.moveItem(atPath: path, toPath: rotated)
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
