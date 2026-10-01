import Foundation

/// Which agent a surface is running. **Derived, never stored** — like `Surface.output` and
/// `resumePlan`, this is computed from what the surface already persists, so there's no side-table to
/// keep in sync (and no way for it to disagree with the resume binding).
///
/// It matters because the two agents report their working state through completely different channels:
/// Claude drives `AgentLifecycle` from hooks (the title spinner only corroborates), while Codex has no
/// hooks in our wrapper at all and its terminal title is the whole signal (see
/// `AgentLifecycleReconciler`).
public enum AgentKind: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex
    case opencode
    case pi

    /// The built-in profile for this agent.
    public var profile: AgentProfile? { AgentProfiles.named(rawValue) }

    /// The kind for an agent name as the wrapper reports it (`SessionReportEvent.agentName`, persisted
    /// on `ResumeBinding.agentName` / `AgentLaunchMetadata.agentName`).
    public static func named(_ name: String?) -> AgentKind? {
        guard let name = name?.nilIfBlank?.lowercased() else { return nil }
        return AgentKind(rawValue: name)
    }

    /// The kind named by a launch command line, e.g. `balagan-agent codex --foo` or
    /// `'/…/balagan-agent' claude`.
    ///
    /// Matched per *token* (on the token's last path component), never as a substring: a tmux binding
    /// like `tmux attach -t task_resume_codex` mentions "codex" but runs no agent, and substring
    /// matching would have mis-typed it.
    public static func inCommand(_ command: String?) -> AgentKind? {
        guard let command = command?.nilIfBlank else { return nil }
        for rawToken in command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`"))
            guard token.isEmpty == false else { continue }
            if let kind = AgentKind(rawValue: (token as NSString).lastPathComponent.lowercased()) {
                return kind
            }
        }
        return nil
    }

    /// Name first (the wrapper reported it, so it's authoritative), then the command lines in the order
    /// given — a surface launched but not yet captured has only its command.
    public static func infer(agentName: String? = nil, commands: [String?] = []) -> AgentKind? {
        if let named = named(agentName) { return named }
        for command in commands {
            if let kind = inCommand(command) { return kind }
        }
        return nil
    }
}

extension Surface {
    /// The agent running on this surface, or nil for a plain shell (and for an agent we don't know
    /// about). Derived from the wrapper-reported agent name, falling back to the launch command.
    public var agentKind: AgentKind? {
        AgentKind.infer(
            agentName: resumeBinding?.agentName ?? agentLaunchMetadata?.agentName,
            commands: [
                startupCommand,
                agentLaunchMetadata?.startupCommand,
                resumeBinding?.command,
                resumeBinding?.argv.joined(separator: " "),
            ]
        )
    }
}
