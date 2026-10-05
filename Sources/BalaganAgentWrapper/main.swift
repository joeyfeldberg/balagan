import Foundation
import Darwin
import BalaganCore

@main
enum BalaganAgentWrapper {
    private static let codexCaptureHelperFlag = "--balagan-codex-capture-helper"
    private static let claudeHookFlag = "hook"
    /// `report <agent> lifecycle <state>` / `report <agent> session <id> [transcript]` — how the pi
    /// extension and the OpenCode plugin talk to Balagan.
    private static let reportFlag = "report"
    /// `statusline` — Claude's status line inside Balagan: records the subscription limits Claude
    /// passes it, then runs the user's own status line (or a compact default).
    private static let statusLineFlag = "statusline"

    static func main() {
        do {
            if CommandLine.arguments.dropFirst().first == codexCaptureHelperFlag {
                try runCodexCaptureHelper(commandLineArguments: CommandLine.arguments)
                exit(0)
            }

            // Claude hooks (installed via --settings below): `hook <event>`, where the events are the
            // cases of `AgentHookEvent`. session-start reports the current session id (so an in-agent
            // /resume stays captured); the rest report the agent's working state (running / idle /
            // needs-input) for the card spinner. Must never block Claude: swallow errors and emit
            // nothing on stdout (a hook's stdout is fed back into Claude, and an empty stdout on
            // PermissionRequest is what keeps it a pure observer of the permission flow).
            if CommandLine.arguments.dropFirst().first == claudeHookFlag {
                runAgentHook(event: CommandLine.arguments.dropFirst(2).first)
                exit(0)
            }

            if CommandLine.arguments.dropFirst().first == statusLineFlag {
                exit(runStatusLine())
            }

            if CommandLine.arguments.dropFirst().first == reportFlag {
                runReport(Array(CommandLine.arguments.dropFirst(2)))
                exit(0)
            }

            try runNormalLaunch()
        } catch let error as AgentWrapperError {
            fputs("balagan-agent: \(error.description)\n", stderr)
            exit(2)
        } catch let error as SessionReportEventSocketError {
            fputs("balagan-agent: \(error.description)\n", stderr)
            exit(2)
        } catch {
            fputs("balagan-agent: \(String(describing: error))\n", stderr)
            exit(2)
        }
    }

    /// The default path: report the agent's session start (or spawn the Codex capture helper for
    /// agents whose session id only appears after launch), install the agent's integration, then exec
    /// the real agent in place. Anything that isn't an interactive agent run inside a Balagan terminal
    /// (a subcommand, `--print`, a nested run from inside an agent, a run outside Balagan, stdin not a
    /// terminal) execs the real binary untouched.
    private static func runNormalLaunch() throws -> Never {
        let environment = ProcessInfo.processInfo.environment
        let wrapperPath = try currentExecutablePath()
        let plan = try AgentWrapperPlanner.plan(
            commandLineArguments: CommandLine.arguments,
            environment: environment,
            excludedDirectories: [(wrapperPath as NSString).deletingLastPathComponent]
        )
        guard plan.mode == .agent,
              isatty(STDIN_FILENO) != 0,
              let balaganEnvironment = try? AgentWrapperEnvironment.parse(environment)
        else {
            execAgent(plan)
        }
        let startMs = currentTimeMilliseconds()
        let cwd = FileManager.default.currentDirectoryPath
        let pid = getpid()

        // Report the start right away, session id or not: the tab becomes an agent tab now, and the id
        // follows when the agent's integration (or the Codex capture helper) learns it.
        var event = plan.sessionStartEvent(
            environment: balaganEnvironment,
            processEnvironment: environment,
            cwd: cwd,
            pid: pid
        )
        // Codex resume: the rollout transcript already exists on disk. (Claude's transcript is
        // created after exec; its SessionStart hook reports the path.)
        if plan.agentName == "codex", plan.sessionID != nil {
            event.transcriptPath = TranscriptLocator.fromEnvironment(environment)
                .resolve(agentName: "codex", sessionID: plan.sessionID)
        }
        // Best-effort: a failed session report must never prevent the agent from launching.
        do {
            try SessionReportEventSocketSender.send(event: event, socketPath: balaganEnvironment.socketPath)
        } catch {
            fputs("balagan-agent: session report failed (continuing): \(String(describing: error))\n", stderr)
            logSessionStartSendFailure(error, environment: environment, balaganEnvironment: balaganEnvironment)
        }
        if plan.needsCodexSessionCapture {
            try startCodexCaptureHelper(
                wrapperEnvironment: balaganEnvironment,
                plan: plan,
                environment: environment,
                cwd: cwd,
                startMs: startMs,
                pid: pid
            )
        }

        var execPlan = plan
        let paths = AgentIntegrationPaths(root: environment["BALAGAN_HOME"] ?? (NSHomeDirectory() + "/.balagan"))
        switch AgentProfiles.named(plan.agentName)?.integration {
        case .claudeHooks:
            // Hooks via --settings, which *merges* with the user's settings: the session id is
            // re-reported on every start/resume (correct after an in-agent `/resume`), and the
            // working-state hooks drive the card spinner. Best-effort.
            if let settingsArgument = try? claudeHookSettingsArgument() {
                execPlan.arguments = ["--settings", settingsArgument] + execPlan.arguments
            }
        case .piExtension:
            if FileManager.default.fileExists(atPath: paths.piExtension) {
                execPlan.arguments = ["--extension", paths.piExtension] + execPlan.arguments
            }
        case .opencodePlugin:
            // Added to the user's config, never replacing it — and only if they haven't pointed
            // OPENCODE_CONFIG_DIR somewhere themselves.
            if environment["OPENCODE_CONFIG_DIR"]?.isEmpty != false,
               FileManager.default.fileExists(atPath: paths.opencodePlugin) {
                setenv("OPENCODE_CONFIG_DIR", paths.opencodeConfigDir, 1)
            }
        case .codexCapture, nil:
            break
        }
        // Inside the agent, a nested run of any agent (a tool calling `claude -p`) must not re-wrap or
        // take over this tab; the integration scripts find the wrapper here.
        setenv("BALAGAN_AGENT_ACTIVE", "1", 1)
        setenv("BALAGAN_AGENT_WRAPPER", wrapperPath, 1)

        execAgent(execPlan)
    }

    /// `report <agent> lifecycle <running|idle|needs-input>` or `report <agent> session <id> [transcript]`.
    /// Called by the pi extension and the OpenCode plugin. Never fails loudly: an integration must not
    /// break the agent, so every outcome is one hook-log line and exit 0.
    private static func runReport(_ arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        let balaganEnvironment = try? AgentWrapperEnvironment.parse(environment)
        let parsed = AgentReportCommand.parse(arguments)
        func log(_ outcome: AgentHookLogOutcome, lifecycle: String? = nil) {
            AgentHookLog.append(
                AgentHookLogEntry(
                    event: "report-\(parsed?.kindName ?? "invalid")",
                    lifecycle: lifecycle,
                    taskID: balaganEnvironment?.taskID,
                    surfaceID: balaganEnvironment?.surfaceID,
                    outcome: outcome
                ),
                environment: environment
            )
        }
        guard let parsed else { log(.droppedNoMapping); return }
        guard let balaganEnvironment else { log(.droppedMissingEnv); return }
        let event = parsed.event(
            environment: balaganEnvironment,
            processEnvironment: environment,
            cwd: FileManager.default.currentDirectoryPath
        )
        do {
            try SessionReportEventSocketSender.send(event: event, socketPath: balaganEnvironment.socketPath)
            log(.sent, lifecycle: event.lifecycle)
        } catch {
            log(.sendFailure(error), lifecycle: event.lifecycle)
        }
    }

    private static func currentTimeMilliseconds() -> Int64 {
        Date().millisecondsSince1970
    }

    private static func startCodexCaptureHelper(
        wrapperEnvironment _: AgentWrapperEnvironment,
        plan: AgentWrapperPlan,
        environment: [String: String],
        cwd: String,
        startMs: Int64,
        pid: pid_t
    ) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: try currentExecutablePath())
        helper.arguments = [
            codexCaptureHelperFlag,
            String(startMs),
            cwd,
            String(pid),
            plan.executablePath,
        ] + plan.arguments
        helper.environment = environment
        helper.currentDirectoryURL = URL(fileURLWithPath: cwd)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private static func runCodexCaptureHelper(commandLineArguments: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        let balaganEnvironment = try AgentWrapperEnvironment.parse(environment)
        guard commandLineArguments.count >= 6,
              let startMs = Int64(commandLineArguments[2]),
              let pid = Int32(commandLineArguments[4])
        else {
            throw AgentWrapperError.missingAgent
        }

        let cwd = commandLineArguments[3]
        let executablePath = commandLineArguments[5]
        let arguments = Array(commandLineArguments.dropFirst(6))
        switch pollCodexSession(cwd: cwd, startMs: startMs, agentPID: pid, environment: environment) {
        case let .captured(sessionID):
            let plan = AgentWrapperPlan(
                agentName: "codex",
                executablePath: executablePath,
                arguments: arguments,
                sessionID: sessionID,
                command: "codex resume \(sessionID)",
                limitation: nil
            )
            var event = plan.sessionStartEvent(
                environment: balaganEnvironment,
                processEnvironment: environment,
                cwd: cwd,
                pid: pid
            )
            event.transcriptPath = TranscriptLocator.fromEnvironment(environment)
                .resolve(agentName: "codex", sessionID: sessionID)
            do {
                try SessionReportEventSocketSender.send(event: event, socketPath: balaganEnvironment.socketPath)
            } catch {
                logSessionStartSendFailure(
                    error,
                    environment: environment,
                    balaganEnvironment: balaganEnvironment
                )
                throw error
            }
        case .ambiguous, .notFound:
            break
        }
    }

    private static func execAgent(_ plan: AgentWrapperPlan) -> Never {
        let argv = ([plan.executablePath] + plan.arguments).map { strdup($0) }
        defer {
            for pointer in argv {
                free(pointer)
            }
        }
        var mutableArgv = argv + [nil]
        if plan.executablePath.contains("/") {
            execv(plan.executablePath, &mutableArgv)
        } else {
            execvp(plan.executablePath, &mutableArgv)
        }
        fputs("balagan-agent: failed to exec \(plan.executablePath): \(String(cString: strerror(errno)))\n", stderr)
        exit(127)
    }

    /// Handles a Claude hook invocation (`hook <event>`): reads the JSON payload on stdin, asks the
    /// pure `AgentHookEvent` mapping what (if anything) to report, and sends it to the session-report
    /// socket — session-start carries the current session id (keeps resume correct across an in-agent
    /// /resume); the rest carry the agent's working state (running/idle/needs-input) for the card
    /// spinner. Resilient: any failure exits 0 with no stdout so Claude is never blocked or polluted.
    private static func runAgentHook(event rawEvent: String?) {
        // Always drain stdin first: the hook's payload is written to us, and every early return below
        // must still leave Claude with a clean pipe.
        let payload = AgentHookPayload.parse(FileHandle.standardInput.readDataToEndOfFile())
        let hookEvent = AgentHookEvent(argument: rawEvent)
        let environment = ProcessInfo.processInfo.environment
        let balaganEnvironment = try? AgentWrapperEnvironment.parse(environment)

        // Every path below ends in exactly one log line, so an unexplained agent state can always be
        // traced to "the hook never fired" vs. "it fired and was dropped/failed to send".
        func log(_ outcome: AgentHookLogOutcome, lifecycle: AgentLifecycle? = nil, toolName: String? = nil) {
            AgentHookLog.append(
                AgentHookLogEntry(
                    event: hookEvent.rawValue,
                    lifecycle: lifecycle?.rawValue,
                    taskID: balaganEnvironment?.taskID,
                    surfaceID: balaganEnvironment?.surfaceID,
                    toolName: toolName,
                    outcome: outcome
                ),
                environment: environment
            )
        }

        // A subagent's hook (payload carries `agent_id`) is dropped by `report(payload:)` too; checked
        // here as well so the log can say *why* it was dropped.
        if hookEvent != .sessionStart, payload.agentID != nil {
            log(.droppedSubagent, toolName: payload.toolName)
            return
        }
        guard let report = hookEvent.report(payload: payload) else {
            log(.droppedNoMapping, toolName: payload.toolName)
            return
        }
        guard let balaganEnvironment else {
            log(.droppedMissingEnv, lifecycle: report.lifecycle, toolName: report.toolName)
            return
        }
        let cwd = payload.cwd ?? FileManager.default.currentDirectoryPath

        // session-start creates/refreshes the resume binding and needs a session id; the working-state
        // events are matched by surface (from env) and don't require one.
        if report.kind == .sessionStart, payload.sessionID == nil {
            log(.droppedNoSessionID, lifecycle: report.lifecycle, toolName: report.toolName)
            return
        }

        let event = SessionReportEvent(
            event: report.kind,
            taskID: balaganEnvironment.taskID,
            workspaceID: balaganEnvironment.workspaceID,
            surfaceID: balaganEnvironment.surfaceID,
            agentName: "claude",
            sessionID: payload.sessionID,
            cwd: cwd,
            transcriptPath: payload.transcriptPath,
            status: "running",
            command: payload.sessionID.map { "claude --resume \($0)" },
            lifecycle: report.lifecycle?.rawValue,
            toolName: report.toolName,
            environment: environment
        )
        do {
            try SessionReportEventSocketSender.send(event: event, socketPath: balaganEnvironment.socketPath)
            log(.sent, lifecycle: report.lifecycle, toolName: report.toolName)
        } catch {
            log(.sendFailure(error), lifecycle: report.lifecycle, toolName: report.toolName)
        }
    }

    /// Records a failed pre-exec / capture-helper session-start report in the hook log, so a missing
    /// resume binding is diagnosable from the same file as the working-state hooks. The stderr line
    /// stays: it is what shows up in the terminal the agent is about to take over.
    private static func logSessionStartSendFailure(
        _ error: Error,
        environment: [String: String],
        balaganEnvironment: AgentWrapperEnvironment?
    ) {
        AgentHookLog.append(
            AgentHookLogEntry(
                event: "launch",
                taskID: balaganEnvironment?.taskID,
                surfaceID: balaganEnvironment?.surfaceID,
                outcome: .sendFailure(error)
            ),
            environment: environment
        )
    }

    /// Builds the `--settings` JSON registering our hooks (one per `AgentHookEvent`) and disabling
    /// Claude's own notification channel. `--settings` *merges* with the user's existing Claude settings
    /// rather than replacing them. Each hook command is the absolute path to this wrapper +
    /// `hook <event>`, shell-quoted (Claude runs the command via a shell).
    private static func claudeHookSettingsArgument() throws -> String {
        try ClaudeHookSettings.json(
            wrapperPath: currentExecutablePath(),
            hookFlag: claudeHookFlag,
            statusLineFlag: statusLineFlag,
            userStatusLine: ClaudeStatusLine.userSetting(projectDirectory: FileManager.default.currentDirectoryPath)
        )
    }

    /// Claude's status line: Claude pipes session JSON in on every refresh and shows what we print.
    /// Saves `rate_limits` for the app's usage meter, then hands the same JSON to the user's own
    /// status line command and passes its output and exit status through. Never fails loudly: a
    /// status line that errors just shows nothing.
    private static func runStatusLine() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        if let limits = object?["rate_limits"] as? [String: Any] {
            try? AgentUsageStore.writeClaude(rateLimits: limits, observedAt: Date())
        }
        let workspace = object?["workspace"] as? [String: Any]
        let projectDirectory = (workspace?["project_dir"] as? String)
            ?? (workspace?["current_dir"] as? String)
            ?? (object?["cwd"] as? String)
        guard let command = (ClaudeStatusLine.userSetting(projectDirectory: projectDirectory)?["command"] as? String)?.nilIfBlank else {
            print(ClaudeStatusLine.defaultLine(statusLineJSON: input))
            return 0
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let projectDirectory, FileManager.default.fileExists(atPath: projectDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: projectDirectory)
        }
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return 1
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func currentExecutablePath() throws -> String {
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw AgentWrapperError.emptyExecutable("balagan-agent")
        }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    /// Codex writes its session file when you send the first message, not at launch — so keep
    /// watching: every 250 ms for the first 10 s (a resume or a quick first prompt), then once a second
    /// until the session appears or Codex is gone (capped at an hour, so a forgotten helper can't linger).
    private static func pollCodexSession(
        cwd: String,
        startMs: Int64,
        agentPID: pid_t,
        environment: [String: String]
    ) -> CodexSessionCaptureResult {
        let capture = CodexSessionCapture.fromEnvironment(environment)
        let started = Date()
        var lastResult = CodexSessionCaptureResult.notFound
        repeat {
            do {
                let result = try capture.capture(cwd: cwd, startMs: startMs)
                switch result {
                case .captured, .ambiguous:
                    return result
                case .notFound:
                    lastResult = result
                }
            } catch {
                fputs("balagan-agent: Codex session capture failed: \(String(describing: error))\n", stderr)
                return .notFound
            }
            if kill(agentPID, 0) != 0, errno == ESRCH { return lastResult }
            usleep(Date().timeIntervalSince(started) < 10 ? 250_000 : 1_000_000)
        } while Date().timeIntervalSince(started) < 3600
        return lastResult
    }
}
