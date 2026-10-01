import Foundation

/// The fields of a Claude Code hook payload (JSON on the hook process's stdin) that Balagan reads.
///
/// Kept deliberately small: the wrapper parses stdin once into this, and every decision about what to
/// report is then a pure function of it (`AgentHookEvent.report(payload:)`), so the whole contract is
/// unit-testable without a running agent.
public struct AgentHookPayload: Equatable, Sendable {
    public var sessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    /// `tool_name` on PreToolUse / PostToolUse / PermissionRequest — the tool the agent is about to
    /// run, has just finished, or is asking permission for.
    public var toolName: String?
    /// `notification_type` on Notification — the structured kind (classified by `AgentNotification`).
    public var notificationType: String?
    /// `agent_id` — present only when the hook fired for a **subagent's** turn/tool call. A background
    /// subagent's PreToolUse would otherwise re-assert "running" on the parent surface and clobber a
    /// real needs-input, so subagent events never drive the surface lifecycle.
    public var agentID: String?

    public init(
        sessionID: String? = nil,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        agentID: String? = nil
    ) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.toolName = toolName
        self.notificationType = notificationType
        self.agentID = agentID
    }

    /// Reads the fields we care about out of a decoded hook payload. Everything is optional: a hook we
    /// don't recognize, or a payload shape that changes, must degrade to "report nothing", never throw.
    public init(json: [String: Any]) {
        self.init(
            sessionID: ((json["session_id"] as? String) ?? (json["sessionId"] as? String))?.nilIfBlank,
            transcriptPath: (json["transcript_path"] as? String)?.nilIfBlank,
            cwd: (json["cwd"] as? String)?.nilIfBlank,
            toolName: (json["tool_name"] as? String)?.nilIfBlank,
            notificationType: (json["notification_type"] as? String)?.nilIfBlank,
            agentID: (json["agent_id"] as? String)?.nilIfBlank
        )
    }

    /// Parses raw hook stdin. Invalid/empty JSON yields an empty payload rather than an error.
    public static func parse(_ data: Data) -> AgentHookPayload {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentHookPayload()
        }
        return AgentHookPayload(json: json)
    }
}

/// A Claude Code hook Balagan installs, and what it means for the agent's working state.
///
/// The set exists to answer one question as promptly as possible: *is this agent working, waiting on
/// me, or done?* The interesting cases, learned by measurement:
///
/// - `PermissionRequest` fires **immediately, before** the permission dialog is drawn. The older
///   `Notification`/`permission_prompt` signal only fires 6 s after the dialog appears and never fires
///   at all if you answer sooner — so on its own "waiting" showed late or not at all.
/// - `PostToolUse` fires when a tool completes, which is what puts an *approved* prompt back into
///   "running": `PreToolUse` runs before the dialog, so nothing else re-asserts running until the
///   agent happens to reach the next tool.
/// - `PreToolUse` for `AskUserQuestion` / `ExitPlanMode` is a block on the user that never goes through
///   the permission dialog — belt-and-braces alongside `PermissionRequest`.
///
/// Every hook is a pure observer: the wrapper exits 0 with empty stdout, so none of them can alter the
/// permission flow or inject text into the agent.
public enum AgentHookEvent: String, CaseIterable, Sendable {
    /// Reports the session id (keeps resume correct across an in-agent `/resume`), not a working state.
    case sessionStart = "session-start"
    case promptSubmit = "prompt-submit"
    case preTool = "pre-tool"
    case postTool = "post-tool"
    case permissionRequest = "permission-request"
    case stop
    case notification

    /// Parses the wrapper's `hook <event>` argument. An absent or unknown argument falls back to
    /// session-start — the original single-hook contract, and the safest default (it can only refresh
    /// the resume binding, never move the working state).
    public init(argument: String?) {
        self = argument.flatMap { AgentHookEvent(rawValue: $0.lowercased()) } ?? .sessionStart
    }

    /// The Claude Code hook name this event is registered under in the injected `--settings` JSON.
    public var claudeHookName: String {
        switch self {
        case .sessionStart: return "SessionStart"
        case .promptSubmit: return "UserPromptSubmit"
        case .preTool: return "PreToolUse"
        case .postTool: return "PostToolUse"
        case .permissionRequest: return "PermissionRequest"
        case .stop: return "Stop"
        case .notification: return "Notification"
        }
    }

    /// Tools whose `PreToolUse` means "blocked on the user" rather than "working": they hand control
    /// back to you without going through the permission dialog.
    public static let userBlockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// What a hook invocation should send to the app — or `nil` for "report nothing".
    public struct Report: Equatable, Sendable {
        public var kind: SessionReportEventKind
        /// The working state to record; `nil` leaves it unchanged (only meaningful for session-start,
        /// which the app ignores for lifecycle purposes).
        public var lifecycle: AgentLifecycle?
        /// The tool the state is about ("waiting on Bash"), when the payload named one.
        public var toolName: String?

        public init(kind: SessionReportEventKind, lifecycle: AgentLifecycle? = nil, toolName: String? = nil) {
            self.kind = kind
            self.lifecycle = lifecycle
            self.toolName = toolName
        }
    }

    /// Maps this hook + its payload onto the report to send. Pure; `nil` means stay silent.
    public func report(payload: AgentHookPayload) -> Report? {
        // Session start is about the session id, not the working state, and is meaningful even for a
        // subagent's payload (the session id is the parent conversation's).
        if self == .sessionStart {
            return Report(kind: .sessionStart, lifecycle: .idle)
        }

        // Subagent hooks fire on the same socket with the same BALAGAN_SURFACE_ID as the parent. Their
        // tool traffic says nothing about whether *you* are being waited on, so drop them entirely.
        guard payload.agentID == nil else { return nil }

        switch self {
        case .sessionStart:
            return nil // handled above
        case .promptSubmit:
            return Report(kind: .lifecycle, lifecycle: .running)
        case .preTool:
            // Fires before every tool — the "still working" heartbeat — except for the two tools that
            // are themselves a question to the user.
            let blocking = payload.toolName.map(AgentHookEvent.userBlockingTools.contains) ?? false
            return Report(kind: .lifecycle, lifecycle: blocking ? .needsInput : .running, toolName: payload.toolName)
        case .postTool:
            // A tool finished, so the agent is working again — this is what clears the needs-input left
            // by an approved permission prompt.
            return Report(kind: .lifecycle, lifecycle: .running, toolName: payload.toolName)
        case .permissionRequest:
            // Fires before the dialog is drawn: the prompt, unlike the Notification hook.
            return Report(kind: .lifecycle, lifecycle: .needsInput, toolName: payload.toolName)
        case .stop:
            return Report(kind: .lifecycle, lifecycle: .idle)
        case .notification:
            // Many things notify; only some mean "blocked on you". Unknown/absent → stay silent.
            guard let mapped = AgentNotification.lifecycle(forNotificationType: payload.notificationType) else {
                return nil
            }
            return Report(kind: .lifecycle, lifecycle: mapped)
        }
    }
}

/// Builds the inline `--settings` JSON the wrapper prepends to every Claude launch (and re-passes on
/// `--resume`). `--settings` *merges* with the user's own settings rather than replacing them.
public enum ClaudeHookSettings {
    /// - Parameters:
    ///   - wrapperPath: absolute path to `balagan-agent` (shell-quoted here; Claude runs hook commands
    ///     through a shell).
    ///   - hookFlag: the wrapper subcommand that dispatches hooks (`hook`).
    /// - Returns: the JSON string to pass as `--settings`.
    public static func json(wrapperPath: String, hookFlag: String = "hook") throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: settingsObject(wrapperPath: wrapperPath, hookFlag: hookFlag),
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// The settings as a plain object (exposed so tests can assert the shape without re-parsing).
    public static func settingsObject(wrapperPath: String, hookFlag: String = "hook") -> [String: Any] {
        let quotedWrapper = wrapperPath.shellQuoted
        var hooks: [String: Any] = [:]
        for event in AgentHookEvent.allCases {
            hooks[event.claudeHookName] = [
                ["hooks": [["type": "command", "command": "\(quotedWrapper) \(hookFlag) \(event.rawValue)"]]],
            ]
        }
        return [
            // Balagan posts its own banners from the lifecycle transitions (and jumps to the waiting
            // surface when you click one), so Claude's native notifications would only double up.
            "preferredNotifChannel": "notifications_disabled",
            "hooks": hooks,
        ]
    }
}
