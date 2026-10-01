import Foundation

public enum AgentWrapperError: Error, Equatable, CustomStringConvertible {
    case missingAgent
    case unsupportedAgent(String)
    case missingBalaganEnvironment([String])
    case emptyExecutable(String)

    public var description: String {
        switch self {
        case .missingAgent:
            return "usage: balagan-agent <claude|codex> [agent arguments...]"
        case let .unsupportedAgent(agent):
            return "unsupported Balagan agent wrapper: \(agent)"
        case let .missingBalaganEnvironment(keys):
            return "missing Balagan environment: \(keys.joined(separator: ", "))"
        case let .emptyExecutable(agent):
            return "empty executable for Balagan agent wrapper: \(agent)"
        }
    }
}

public struct AgentWrapperEnvironment: Equatable, Sendable {
    public var taskID: String
    public var workspaceID: String
    public var surfaceID: String
    public var socketPath: String

    public init(taskID: String, workspaceID: String, surfaceID: String, socketPath: String) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.socketPath = socketPath
    }

    public static func parse(_ environment: [String: String]) throws -> AgentWrapperEnvironment {
        let values = [
            "BALAGAN_TASK_ID": environment["BALAGAN_TASK_ID"],
            "BALAGAN_WORKSPACE_ID": environment["BALAGAN_WORKSPACE_ID"],
            "BALAGAN_SURFACE_ID": environment["BALAGAN_SURFACE_ID"],
            "BALAGAN_SOCKET_PATH": environment["BALAGAN_SOCKET_PATH"],
        ]
        let missing = values.compactMap { key, value in
            value?.isEmpty == false ? nil : key
        }.sorted()
        guard missing.isEmpty else {
            throw AgentWrapperError.missingBalaganEnvironment(missing)
        }
        return AgentWrapperEnvironment(
            taskID: values["BALAGAN_TASK_ID"]!!,
            workspaceID: values["BALAGAN_WORKSPACE_ID"]!!,
            surfaceID: values["BALAGAN_SURFACE_ID"]!!,
            socketPath: values["BALAGAN_SOCKET_PATH"]!!
        )
    }
}

public struct AgentWrapperPlan: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// An interactive agent run: report the session, install the integration, then exec.
        case agent
        /// Not an agent session (a subcommand, `--print`, `--help`, or already inside an agent): exec the
        /// real binary untouched, report nothing — the tab stays whatever it was.
        case passthrough
    }

    public var mode: Mode = .agent
    public var agentName: String
    public var executablePath: String
    public var arguments: [String]
    public var sessionID: String?
    public var command: String
    public var limitation: String?
    public var needsCodexSessionCapture: Bool

    public init(
        agentName: String,
        executablePath: String,
        arguments: [String],
        sessionID: String?,
        command: String,
        limitation: String?,
        needsCodexSessionCapture: Bool = false
    ) {
        self.agentName = agentName
        self.executablePath = executablePath
        self.arguments = arguments
        self.sessionID = sessionID
        self.command = command
        self.limitation = limitation
        self.needsCodexSessionCapture = needsCodexSessionCapture
    }

    public var argv: [String] {
        [executablePath] + arguments
    }

    public func sessionStartEvent(
        environment balaganEnvironment: AgentWrapperEnvironment,
        processEnvironment: [String: String],
        cwd: String,
        pid: Int32?,
        reportedAt: Date? = nil
    ) -> SessionReportEvent {
        SessionReportEvent(
            event: .sessionStart,
            taskID: balaganEnvironment.taskID,
            workspaceID: balaganEnvironment.workspaceID,
            surfaceID: balaganEnvironment.surfaceID,
            agentName: agentName,
            sessionID: sessionID,
            pid: pid,
            executablePath: executablePath,
            argv: argv,
            cwd: cwd,
            status: "running",
            command: command,
            environment: processEnvironment,
            reportedAt: reportedAt
        )
    }
}

public enum AgentWrapperPlanner {
    /// Plans a `balagan-agent <agent> [arguments…]` launch.
    ///
    /// - Parameters:
    ///   - excludedDirectories: directories to skip when finding the real binary on `PATH` — the shims
    ///     folder and the wrapper's own — so a shim can't resolve to itself.
    public static func plan(
        commandLineArguments: [String],
        environment: [String: String],
        excludedDirectories: [String] = [],
        uuid: () -> UUID = UUID.init,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> AgentWrapperPlan {
        guard commandLineArguments.count >= 2 else {
            throw AgentWrapperError.missingAgent
        }
        let agentName = commandLineArguments[1].lowercased()
        let arguments = Array(commandLineArguments.dropFirst(2))
        guard let profile = AgentProfiles.named(agentName) else {
            throw AgentWrapperError.unsupportedAgent(agentName)
        }
        let executable = try resolveExecutable(
            profile: profile,
            environment: environment,
            excludedDirectories: excludedDirectories + [environment["BALAGAN_SHIMS_DIR"]].compactMap { $0 },
            isExecutable: isExecutable
        )

        // Already inside an agent (a tool call running `claude -p …`, Codex calling itself) or not an
        // interactive run at all: never take over the tab's binding.
        if environment["BALAGAN_AGENT_ACTIVE"]?.isEmpty == false
            || AgentLaunchClassifier.isInteractiveRun(profile, arguments: arguments) == false {
            var plan = AgentWrapperPlan(
                agentName: profile.id,
                executablePath: executable,
                arguments: arguments,
                sessionID: nil,
                command: ([profile.command] + arguments).joined(separator: " "),
                limitation: nil
            )
            plan.mode = .passthrough
            return plan
        }

        var plan: AgentWrapperPlan
        switch profile.id {
        case "claude":
            plan = try claudePlan(arguments: arguments, environment: environment, uuid: uuid)
        case "codex":
            plan = try codexPlan(arguments: arguments, environment: environment)
        default:
            plan = genericPlan(profile: profile, arguments: arguments, environment: environment, uuid: uuid)
        }
        plan.executablePath = executable
        return plan
    }

    /// Any agent described by a profile: inject a fresh session id when it takes one and you didn't pick
    /// a session yourself; otherwise take the one you named (the session may also be reported later by
    /// the agent's own integration, e.g. OpenCode's plugin).
    static func genericPlan(
        profile: AgentProfile,
        arguments: [String],
        environment: [String: String],
        uuid: () -> UUID
    ) -> AgentWrapperPlan {
        var launchArguments = arguments
        var sessionID: String?
        if AgentLaunchClassifier.userChoseSession(profile, arguments: arguments) {
            sessionID = AgentLaunchClassifier.namedSession(profile, arguments: arguments)
        } else if let flag = profile.sessionIDFlag {
            let fresh = uuid().uuidString.lowercased()
            sessionID = fresh
            launchArguments = [flag, fresh] + arguments
        }
        if profile.id == "pi",
           AgentLaunchClassifier.userChoseSession(profile, arguments: arguments) == false,
           let name = environment["BALAGAN_AGENT_NAME"].flatMap(nilIfBlank),
           arguments.contains(where: { $0 == "--name" || $0 == "-n" || $0.hasPrefix("--name=") }) == false {
            launchArguments = ["--name", name] + launchArguments
        }
        return AgentWrapperPlan(
            agentName: profile.id,
            executablePath: profile.command,
            arguments: launchArguments,
            sessionID: sessionID,
            command: sessionID.flatMap { profile.resumeCommand(sessionID: $0) } ?? profile.command,
            limitation: nil
        )
    }

    /// `BALAGAN_<ID>_EXECUTABLE` wins; otherwise the first `<command>` on `PATH` that isn't one of
    /// ours; otherwise the bare command (exec will report it missing).
    static func resolveExecutable(
        profile: AgentProfile,
        environment: [String: String],
        excludedDirectories: [String],
        isExecutable: (String) -> Bool
    ) throws -> String {
        let overrideKey = "BALAGAN_\(profile.id.uppercased().replacingOccurrences(of: "-", with: "_"))_EXECUTABLE"
        if let override = environment[overrideKey] {
            guard override.isEmpty == false else { throw AgentWrapperError.emptyExecutable(profile.id) }
            return override
        }
        return AgentExecutableResolver.resolve(
            command: profile.command,
            path: environment["PATH"],
            excluding: excludedDirectories,
            isExecutable: isExecutable
        ) ?? profile.command
    }

    private static func claudePlan(
        arguments: [String],
        environment: [String: String],
        uuid: () -> UUID
    ) throws -> AgentWrapperPlan {
        let executable = try executablePath(
            agentName: "claude",
            overrideEnvironmentKey: "BALAGAN_CLAUDE_EXECUTABLE",
            environment: environment
        )
        if let sessionID = value(afterAnyOf: ["--resume", "-r", "--session-id"], in: arguments) {
            return AgentWrapperPlan(
                agentName: "claude",
                executablePath: executable,
                arguments: arguments,
                sessionID: sessionID,
                command: "claude --resume \(sessionID)",
                limitation: nil
            )
        }

        let sessionID = uuid().uuidString.lowercased()
        var injected = ["--session-id", sessionID]
        // Name the session (Claude's `--name`, from the task title via BALAGAN_AGENT_NAME) so another
        // agent can discover and message it (ListAgents / cross-session messaging). The name persists
        // across `--resume`, so this fresh-launch injection is enough; never override a name the caller
        // already passed.
        let hasName = arguments.contains { $0 == "--name" || $0 == "-n" || $0.hasPrefix("--name=") }
        if hasName == false, let name = environment["BALAGAN_AGENT_NAME"].flatMap(nilIfBlank) {
            injected += ["--name", name]
        }
        return AgentWrapperPlan(
            agentName: "claude",
            executablePath: executable,
            arguments: injected + arguments,
            sessionID: sessionID,
            command: "claude --resume \(sessionID)",
            limitation: nil
        )
    }

    private static func codexPlan(
        arguments: [String],
        environment: [String: String]
    ) throws -> AgentWrapperPlan {
        let executable = try executablePath(
            agentName: "codex",
            overrideEnvironmentKey: "BALAGAN_CODEX_EXECUTABLE",
            environment: environment
        )
        let sessionID = environment["BALAGAN_AGENT_SESSION_ID"]
            ?? value(afterAnyOf: ["--session-id", "--session"], in: arguments)
            ?? value(afterCodexResumeIn: arguments)
        let command = sessionID.map { "codex resume \($0)" } ?? "codex"
        return AgentWrapperPlan(
            agentName: "codex",
            executablePath: executable,
            arguments: arguments,
            sessionID: sessionID,
            command: command,
            limitation: nil,
            needsCodexSessionCapture: sessionID == nil
        )
    }

    private static func executablePath(
        agentName: String,
        overrideEnvironmentKey: String,
        environment: [String: String]
    ) throws -> String {
        let executable = environment[overrideEnvironmentKey] ?? agentName
        guard executable.isEmpty == false else {
            throw AgentWrapperError.emptyExecutable(agentName)
        }
        return executable
    }

    private static func value(afterAnyOf options: Set<String>, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            for option in options {
                if argument == option, arguments.indices.contains(index + 1) {
                    return nilIfBlank(arguments[index + 1])
                }
                let prefix = option + "="
                if argument.hasPrefix(prefix) {
                    return nilIfBlank(String(argument.dropFirst(prefix.count)))
                }
            }
        }
        return nil
    }

    private static func value(afterCodexResumeIn arguments: [String]) -> String? {
        guard let resumeIndex = arguments.firstIndex(of: "resume") else {
            return nil
        }
        for argument in arguments.dropFirst(resumeIndex + 1) {
            if argument.hasPrefix("-") {
                continue
            }
            return nilIfBlank(argument)
        }
        return nil
    }

    private static func nilIfBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
