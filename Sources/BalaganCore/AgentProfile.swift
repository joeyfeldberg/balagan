import Foundation

/// How Balagan runs one coding agent: how to launch it, how to know its session, how to resume it,
/// and which of its own signals report its working state. Built-ins cover Claude Code, Codex, OpenCode
/// and pi; anything else can be described in `~/.balagan/agents/<id>.json` (see `AgentProfiles`).
///
/// A profile is data. The wrapper (`balagan-agent <id> …`) and the resume planner read it instead of
/// branching on agent names, so a new agent is a new profile, not new code — except for the deep
/// integrations (hooks, plugins, extensions), which only built-ins get.
public struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    /// The agents' own state channels Balagan knows how to install. Built-in profiles only.
    public enum Integration: String, Codable, Equatable, Sendable {
        /// Claude Code hooks via `--settings` (working state + session id).
        case claudeHooks
        /// Codex: session id captured from its rollout files; state from its terminal title.
        case codexCapture
        /// pi: an extension loaded with `--extension` reports state and the session.
        case piExtension
        /// OpenCode: a plugin loaded through `OPENCODE_CONFIG_DIR` reports state and the session.
        case opencodePlugin
    }

    /// Stable id: the wrapper's first argument (`balagan-agent <id>`) and the reported agent name.
    public var id: String
    public var displayName: String
    /// The executable name you type in a shell and that's looked up on `PATH`.
    public var command: String
    /// A flag that assigns a fresh session id up front (`--session-id`), when the agent supports it.
    /// Balagan then knows the id before the agent even starts.
    public var sessionIDFlag: String?
    /// Arguments that resume a session, with `{session}` for the id (`["--resume", "{session}"]`).
    public var resumeArguments: [String]?
    /// Flags that mean "you picked the session yourself" — Balagan then doesn't inject one. The first
    /// value after one of them that looks like an id is taken as the session.
    public var sessionFlags: [String]
    /// Subcommands (first positional argument) that aren't an interactive agent run — `login`,
    /// `mcp`, `run` — so the tab stays a plain terminal.
    public var passthroughSubcommands: [String]
    /// Flags that make a run one-shot / non-interactive (`-p`, `--print`).
    public var passthroughFlags: [String]
    public var integration: Integration?

    public init(
        id: String,
        displayName: String,
        command: String,
        sessionIDFlag: String? = nil,
        resumeArguments: [String]? = nil,
        sessionFlags: [String] = [],
        passthroughSubcommands: [String] = [],
        passthroughFlags: [String] = [],
        integration: Integration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.sessionIDFlag = sessionIDFlag
        self.resumeArguments = resumeArguments
        self.sessionFlags = sessionFlags
        self.passthroughSubcommands = passthroughSubcommands
        self.passthroughFlags = passthroughFlags
        self.integration = integration
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, command, sessionIDFlag, resumeArguments, sessionFlags
        case passthroughSubcommands, passthroughFlags, integration
    }

    /// Custom profiles are hand-written JSON, so everything but `id` is optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? id.lowercased()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        sessionIDFlag = try c.decodeIfPresent(String.self, forKey: .sessionIDFlag)
        resumeArguments = try c.decodeIfPresent([String].self, forKey: .resumeArguments)
        sessionFlags = try c.decodeIfPresent([String].self, forKey: .sessionFlags) ?? []
        passthroughSubcommands = try c.decodeIfPresent([String].self, forKey: .passthroughSubcommands) ?? []
        passthroughFlags = try c.decodeIfPresent([String].self, forKey: .passthroughFlags) ?? []
        integration = try c.decodeIfPresent(Integration.self, forKey: .integration)
    }

    /// The argv that resumes `sessionID`, or nil when the agent can't resume by id.
    public func resumeArgv(sessionID: String) -> [String]? {
        guard let resumeArguments, resumeArguments.contains("{session}") else { return nil }
        return [command] + resumeArguments.map { $0 == "{session}" ? sessionID : $0 }
    }

    /// The resume command as one line (for the binding's display command).
    public func resumeCommand(sessionID: String) -> String? {
        resumeArgv(sessionID: sessionID)?.joined(separator: " ")
    }

    /// Which signals report this agent's working state, in words, for Settings.
    public var signalSummary: String {
        switch integration {
        case .claudeHooks: return "Hooks: working, waiting for you, finished. Resumes by session."
        case .codexCapture: return "Terminal title: working, waiting for you, idle. Resumes by session."
        case .piExtension: return "Extension: working, waiting for you, finished. Resumes by session."
        case .opencodePlugin: return "Plugin: working, waiting for you, finished. Resumes by session."
        case nil:
            let resume = resumeArguments == nil ? "No resume." : "Resumes by session."
            return "Terminal title and notifications only. \(resume)"
        }
    }
}

/// The agents Balagan knows: the built-ins plus any custom profiles.
public enum AgentProfiles {
    public static let claude = AgentProfile(
        id: "claude",
        displayName: "Claude Code",
        command: "claude",
        sessionIDFlag: "--session-id",
        resumeArguments: ["--resume", "{session}"],
        sessionFlags: ["--resume", "-r", "--session-id", "--continue", "-c"],
        passthroughSubcommands: [
            "mcp", "config", "doctor", "update", "upgrade", "install", "setup-token", "migrate-installer",
            "plugin", "plugins", "auth", "login", "logout",
        ],
        passthroughFlags: ["-p", "--print", "-v", "--version", "-h", "--help"],
        integration: .claudeHooks
    )

    public static let codex = AgentProfile(
        id: "codex",
        displayName: "Codex",
        command: "codex",
        resumeArguments: ["resume", "{session}"],
        sessionFlags: ["--session-id", "--session"],
        passthroughSubcommands: [
            "exec", "e", "login", "logout", "mcp", "mcp-server", "app-server", "completion", "sandbox",
            "debug", "apply", "a", "cloud", "features", "generate-ts", "help", "proto", "responses-api-proxy",
        ],
        passthroughFlags: ["-V", "--version", "-h", "--help"],
        integration: .codexCapture
    )

    public static let opencode = AgentProfile(
        id: "opencode",
        displayName: "OpenCode",
        command: "opencode",
        resumeArguments: ["--session", "{session}"],
        sessionFlags: ["--session", "-s"],
        passthroughSubcommands: [
            "completion", "acp", "mcp", "attach", "run", "debug", "providers", "auth", "agent", "upgrade",
            "uninstall", "serve", "web", "models", "stats", "export", "import", "github", "session",
            "plugin", "plug", "db",
        ],
        passthroughFlags: ["-v", "--version", "-h", "--help"],
        integration: .opencodePlugin
    )

    public static let pi = AgentProfile(
        id: "pi",
        displayName: "pi",
        command: "pi",
        sessionIDFlag: "--session-id",
        resumeArguments: ["--session-id", "{session}"],
        sessionFlags: ["--session-id", "--session", "--continue", "-c", "--resume", "-r", "--fork", "--no-session"],
        passthroughSubcommands: ["install", "remove", "uninstall", "update", "list", "config", "auth"],
        passthroughFlags: ["-p", "--print", "--export", "--list-models", "-v", "--version", "-h", "--help", "--mode"],
        integration: .piExtension
    )

    public static let builtIns: [AgentProfile] = [claude, codex, opencode, pi]

    /// The live registry: built-ins plus custom profiles loaded at launch (`loadCustom`). The resume
    /// planner and the wrapper read it.
    nonisolated(unsafe) public static var all: [AgentProfile] = builtIns

    public static func named(_ id: String?) -> AgentProfile? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), id.isEmpty == false else {
            return nil
        }
        return all.first { $0.id == id }
    }

    /// The profile whose command a token is (`/opt/homebrew/bin/codex` → codex).
    public static func forCommand(_ token: String) -> AgentProfile? {
        let name = (token as NSString).lastPathComponent.lowercased()
        return all.first { $0.command.lowercased() == name } ?? named(name)
    }

    /// Where custom profiles live.
    public static func customDirectory(home: String = NSHomeDirectory()) -> String {
        home + "/.balagan/agents"
    }

    /// Built-ins plus every valid `*.json` in `directory`. A custom profile can't take a built-in's id
    /// and can't claim a built-in integration (those need Balagan's own code). Bad files are skipped.
    public static func loadCustom(directory: String = customDirectory()) -> [AgentProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var custom: [AgentProfile] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(file)),
                  var profile = try? JSONDecoder().decode(AgentProfile.self, from: data)
            else { continue }
            profile.id = profile.id.lowercased()
            guard builtIns.contains(where: { $0.id == profile.id }) == false,
                  custom.contains(where: { $0.id == profile.id }) == false,
                  isSafeCommandName(profile.command)
            else { continue }
            profile.integration = nil
            custom.append(profile)
        }
        return builtIns + custom
    }

    /// A shim is written for every profile's command, so the name must be a plain file name.
    static func isSafeCommandName(_ name: String) -> Bool {
        name.isEmpty == false && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            && name.hasPrefix(".") == false
    }
}

/// Whether a command line is an interactive agent run (the tab becomes an agent tab) or something
/// else — a subcommand, a one-shot print, `--help` — which runs the real binary untouched.
public enum AgentLaunchClassifier {
    public static func isInteractiveRun(_ profile: AgentProfile, arguments: [String]) -> Bool {
        for argument in arguments {
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if profile.passthroughFlags.contains(flag) { return false }
        }
        // The first positional (non-flag) argument decides whether it's a subcommand.
        if let first = arguments.first(where: { $0.hasPrefix("-") == false }),
           profile.passthroughSubcommands.contains(first) {
            return false
        }
        return true
    }

    /// The session the user named on the command line, if any: the value after one of the profile's
    /// session flags (`--session-id X`, `--resume=X`).
    public static func namedSession(_ profile: AgentProfile, arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            for flag in profile.sessionFlags {
                if argument == flag, arguments.indices.contains(index + 1) {
                    let value = arguments[index + 1]
                    if value.hasPrefix("-") == false, value.isEmpty == false { return value }
                }
                if argument.hasPrefix(flag + "=") {
                    let value = String(argument.dropFirst(flag.count + 1))
                    if value.isEmpty == false { return value }
                }
            }
        }
        return nil
    }

    /// Whether the user took charge of the session (named one, asked to continue/pick one, or asked
    /// for none) — then Balagan must not inject its own id.
    public static func userChoseSession(_ profile: AgentProfile, arguments: [String]) -> Bool {
        arguments.contains { argument in
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            return profile.sessionFlags.contains(flag)
        }
    }
}

/// Finds the real agent binary on `PATH`, skipping Balagan's shims (a shim resolving to itself
/// would loop forever) and the wrapper's own directory.
public enum AgentExecutableResolver {
    public static func resolve(
        command: String,
        path: String?,
        excluding excluded: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if command.contains("/") { return isExecutable(command) ? command : nil }
        let skip = Set(excluded.map(standardize))
        for directory in (path ?? "").split(separator: ":").map(String.init) where directory.isEmpty == false {
            guard skip.contains(standardize(directory)) == false else { continue }
            let candidate = (directory as NSString).appendingPathComponent(command)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private static func standardize(_ path: String) -> String {
        var trimmed = (path as NSString).standardizingPath
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// `balagan-agent report …`, the channel an agent's own integration (pi extension, OpenCode plugin)
/// uses to tell Balagan what's happening:
///
/// - `report <agent> lifecycle <running|idle|needs-input>`
/// - `report <agent> session <id> [transcript-path]`
public struct AgentReportCommand: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lifecycle(AgentLifecycle)
        case session(id: String, transcriptPath: String?)
    }

    public var agent: String
    public var kind: Kind

    public var kindName: String {
        switch kind {
        case .lifecycle: return "lifecycle"
        case .session: return "session"
        }
    }

    public static func parse(_ arguments: [String]) -> AgentReportCommand? {
        guard arguments.count >= 3 else { return nil }
        let agent = arguments[0].lowercased()
        guard agent.isEmpty == false else { return nil }
        switch arguments[1] {
        case "lifecycle":
            guard let state = AgentLifecycle(rawValue: arguments[2]) else { return nil }
            return AgentReportCommand(agent: agent, kind: .lifecycle(state))
        case "session":
            let id = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.isEmpty == false else { return nil }
            let transcript = arguments.count > 3 ? arguments[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return AgentReportCommand(agent: agent, kind: .session(id: id, transcriptPath: transcript.isEmpty ? nil : transcript))
        default:
            return nil
        }
    }

    public func event(
        environment: AgentWrapperEnvironment,
        processEnvironment: [String: String],
        cwd: String
    ) -> SessionReportEvent {
        switch kind {
        case .lifecycle(let state):
            return SessionReportEvent(
                event: .lifecycle,
                taskID: environment.taskID,
                workspaceID: environment.workspaceID,
                surfaceID: environment.surfaceID,
                agentName: agent,
                cwd: cwd,
                status: "running",
                lifecycle: state.rawValue,
                environment: processEnvironment
            )
        case .session(let id, let transcriptPath):
            return SessionReportEvent(
                event: .sessionStart,
                taskID: environment.taskID,
                workspaceID: environment.workspaceID,
                surfaceID: environment.surfaceID,
                agentName: agent,
                sessionID: id,
                cwd: cwd,
                transcriptPath: transcriptPath,
                status: "running",
                command: AgentProfiles.named(agent)?.resumeCommand(sessionID: id),
                environment: processEnvironment
            )
        }
    }
}
