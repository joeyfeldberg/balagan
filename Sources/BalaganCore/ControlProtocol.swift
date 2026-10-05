import Darwin
import Foundation

/// Shared definition of the local **control socket** that the `balagan` CLI uses to drive the
/// running app (list / create / open tasks, query state). The app binds this socket; the CLI connects
/// to it. Both sides resolve the same path and speak the same one-line JSON request/response protocol
/// — no discovery handshake needed.
///
/// Wire format (each message is a single newline-terminated line of JSON):
///   request:  `{"method":"tasks","params":{"project":"acme"}}\n`
///   response: `{"ok":true,"result":{...}}\n`  or  `{"ok":false,"error":"message"}\n`
public enum ControlSocket {
    /// Environment override for the socket path (used by both app and CLI so they always agree).
    public static let environmentKey = "BALAGAN_CONTROL_SOCKET"

    /// The default control socket path: `~/.balagan/control.sock`, unless overridden by the env var.
    /// Kept short (well under the ~104-byte `sockaddr_un` limit) and in a stable, well-known location
    /// so the CLI can reach a running app with zero configuration.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            return override
        }
        return homeDirectory + "/.balagan/control.sock"
    }
}

/// A control request on the wire: a method name plus simple string parameters.
public struct ControlRequest: Codable, Equatable, Sendable {
    public var method: String
    public var params: [String: String]

    public init(method: String, params: [String: String] = [:]) {
        self.method = method
        self.params = params
    }
}

public enum ControlWire {
    /// Encode a request as a single newline-terminated JSON line.
    public static func encodeRequestLine(_ request: ControlRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(request)
        data.append(0x0a)
        return data
    }

    /// Decode a request from a single JSON line (newline already stripped). Returns nil if malformed.
    public static func decodeRequestLine(_ line: String) -> ControlRequest? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ControlRequest.self, from: data)
    }
}

// MARK: - CLI argument parsing

/// A parsed CLI invocation: the request to send, plus client-side options (raw JSON output, an
/// explicit socket path override).
public struct ControlInvocation: Equatable, Sendable {
    public var request: ControlRequest
    public var rawJSON: Bool
    public var socketPath: String?

    public init(request: ControlRequest, rawJSON: Bool = false, socketPath: String? = nil) {
        self.request = request
        self.rawJSON = rawJSON
        self.socketPath = socketPath
    }
}

public enum ControlCLIParseResult: Equatable, Sendable {
    case invocation(ControlInvocation)
    case help
    case error(String)
}

/// Pure, testable mapping from CLI arguments (without the executable name) to a `ControlInvocation`.
/// Keeps the wire mapping out of the thin `main.swift` so it can be unit-tested without a socket.
public enum ControlCLI {
    public static let usage = """
    balagan — control the running Balagan app from the command line

    USAGE:
      balagan <command> [options]

    COMMANDS:
      ping                          Check the app is running and reachable
      projects                      List projects (id, name, repo path)
      tasks [--project <id>]        List tasks, optionally filtered to one project
      create --project <id> --title <text>
             [--branch <b>] [--notes <n>] [--status <s>] [--priority <p>] [--eager]
             (creates in the background; --branch adds a worktree, created on first
              open unless --eager creates it now)
                                    Create a task
      open <task-id>                Select and focus a task (brings the app forward)
      restart <task-id>             Kill the task's agent and relaunch it, resuming its session
      status                        Show the current selection and which agents are running
      state <task-id>               Print a task's aggregate agent state: running / needs-input /
                                    idle / asleep / none
      wait <task-id> [--until <s,…>] [--timeout <ms>]
                                    Block until the task's agent reaches one of the --until states
                                    (default: idle,needs-input) — how an orchestrator waits for a
                                    sub-agent it directed. Omit --timeout to wait indefinitely.
      reader                        Toggle reader mode on the selected task
      speak [<task-id>] [--dry-run] Speak the last agent response (of the selected task by default);
                                    --dry-run prints the speakable text instead of playing audio
      autosleep [--now]             Show which tasks auto-sleep would put to sleep, and why the
                                    rest stay awake; --now runs that pass immediately
      usage                         Claude and Codex subscription limits: how much of each window
                                    is used, and when it resets

    GLOBAL OPTIONS:
      --json                        Print the raw JSON response instead of formatted text
      --socket <path>               Control socket path
                                    (default: $BALAGAN_CONTROL_SOCKET or ~/.balagan/control.sock)
      -h, --help                    Show this help

    Any command containing a dot (e.g. `balagan task.open --id foo`) is sent verbatim as the
    method, with every --flag passed through as a string parameter.
    """

    public static func parse(_ arguments: [String]) -> ControlCLIParseResult {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var rawJSON = false
        var socketPath: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-h", "--help", "help":
                return .help
            case "--json":
                rawJSON = true
            case "--dry-run", "--eager", "--now":
                // Boolean flags (the generic --key form below consumes a value).
                flags[String(arg.dropFirst(2))] = "1"
            case "--socket":
                index += 1
                guard index < arguments.count else { return .error("--socket requires a path") }
                socketPath = arguments[index]
            default:
                if arg.hasPrefix("--") {
                    let key = String(arg.dropFirst(2))
                    index += 1
                    guard index < arguments.count else { return .error("--\(key) requires a value") }
                    flags[key] = arguments[index]
                } else {
                    positionals.append(arg)
                }
            }
            index += 1
        }

        guard let command = positionals.first else { return .help }
        let rest = Array(positionals.dropFirst())

        func make(_ method: String, _ params: [String: String]) -> ControlCLIParseResult {
            .invocation(ControlInvocation(
                request: ControlRequest(method: method, params: params),
                rawJSON: rawJSON,
                socketPath: socketPath
            ))
        }

        switch command {
        case "ping", "status", "projects", "usage":
            return make(command, [:])
        case "tasks":
            var params: [String: String] = [:]
            if let project = flags["project"]?.nilIfBlank { params["project"] = project }
            return make("tasks", params)
        case "create":
            guard let project = flags["project"]?.nilIfBlank else {
                return .error("create requires --project <id>")
            }
            guard let title = flags["title"]?.nilIfBlank else {
                return .error("create requires --title <text>")
            }
            var params: [String: String] = ["project": project, "title": title]
            for key in ["branch", "notes", "status", "priority"] {
                if let value = flags[key]?.nilIfBlank { params[key] = value }
            }
            if flags["eager"] != nil { params["eager"] = "1" }
            return make("task.create", params)
        case "open":
            guard let id = (rest.first ?? flags["id"])?.nilIfBlank else {
                return .error("open requires a task id (e.g. `balagan open my-task`)")
            }
            return make("task.open", ["id": id])
        case "restart":
            guard let id = (rest.first ?? flags["id"])?.nilIfBlank else {
                return .error("restart requires a task id (e.g. `balagan restart my-task`)")
            }
            return make("task.restart", ["id": id])
        case "state":
            guard let id = (rest.first ?? flags["id"])?.nilIfBlank else {
                return .error("state requires a task id (e.g. `balagan state my-task`)")
            }
            return make("task.state", ["id": id])
        case "wait":
            guard let id = (rest.first ?? flags["id"])?.nilIfBlank else {
                return .error("wait requires a task id (e.g. `balagan wait my-task --until idle`)")
            }
            var params = ["id": id]
            if let until = flags["until"]?.nilIfBlank { params["until"] = until }
            if let timeout = flags["timeout"]?.nilIfBlank { params["timeout"] = timeout }
            return make("task.wait", params)
        case "reader":
            return make("reader.toggle", [:])
        case "autosleep":
            return make("autosleep", flags["now"] != nil ? ["now": "1"] : [:])
        case "speak":
            var params: [String: String] = [:]
            if let id = (rest.first ?? flags["id"])?.nilIfBlank { params["id"] = id }
            if flags["dry-run"] != nil { params["dry-run"] = "1" }
            return make("task.speak", params)
        default:
            // Power-user passthrough: a dotted method is sent verbatim with its flags as params.
            if command.contains(".") {
                return make(command, flags)
            }
            return .error("unknown command: \(command) — run `balagan --help`")
        }
    }
}

// MARK: - Client

/// Connects to the control socket, sends one request line, and reads the response line. Used by the
/// `balagan` CLI. Mirrors `SessionReportEventSocketSender`'s socket setup, plus a bounded read of the
/// response.
public enum ControlSocketClient {
    public static func send(
        request: ControlRequest,
        socketPath: String,
        timeout: TimeInterval = 5
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketClientError.socketFailed(errno) }
        defer { Darwin.close(fd) }

        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        guard socketPath.utf8.count < UnixSocketHelpers.maxPathLength else {
            throw ControlSocketClientError.pathTooLong(socketPath)
        }
        let address = UnixSocketHelpers.makeAddress(path: socketPath)

        guard UnixSocketHelpers.connect(fd, to: address) == 0 else {
            throw ControlSocketClientError.connectFailed(socketPath: socketPath, errno: errno)
        }

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let requestData = try ControlWire.encodeRequestLine(request)
        try requestData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < requestData.count {
                let count = Darwin.write(fd, base.advanced(by: written), requestData.count - written)
                guard count > 0 else { throw ControlSocketClientError.writeFailed(errno) }
                written += count
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.contains(0x0a) == false {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break // EOF, timeout, or error
        }
        return data
    }
}

public enum ControlSocketClientError: Error, CustomStringConvertible, Equatable {
    case socketFailed(Int32)
    case pathTooLong(String)
    case connectFailed(socketPath: String, errno: Int32)
    case writeFailed(Int32)

    public var description: String {
        switch self {
        case let .socketFailed(errno):
            return "socket(AF_UNIX) failed with errno \(errno)"
        case let .pathTooLong(path):
            return "socket path is too long: \(path)"
        case let .connectFailed(socketPath, errno):
            return "connect(\(socketPath)) failed with errno \(errno)"
        case let .writeFailed(errno):
            return "write failed with errno \(errno)"
        }
    }
}
