import Foundation

public struct ResumeCommandPlan: Codable, Equatable, Hashable, Sendable {
    public var surfaceID: Surface.ID
    public var kind: ResumeKind
    public var displayCommand: String
    public var argv: [String]?
    public var agentName: String?
    public var sessionID: String?
    public var trust: ResumeTrust
    public var requiresConfirmation: Bool

    public init(
        surfaceID: Surface.ID,
        kind: ResumeKind,
        displayCommand: String,
        argv: [String]?,
        agentName: String? = nil,
        sessionID: String? = nil,
        trust: ResumeTrust,
        requiresConfirmation: Bool
    ) {
        self.surfaceID = surfaceID
        self.kind = kind
        self.displayCommand = displayCommand
        self.argv = argv
        self.agentName = agentName
        self.sessionID = sessionID
        self.trust = trust
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum ResumeCommandPlanner {
    public static func plan(
        for binding: ResumeBinding,
        taskID: Task.ID,
        cwd: String
    ) -> ResumeCommandPlan {
        switch binding.kind {
        case .agent:
            return agentPlan(for: binding)
        case .tmux:
            let argv = binding.sessionID.map { ["tmux", "attach", "-t", $0] }
                ?? Tmux.attachCommand(forTaskID: taskID)
            return ResumeCommandPlan(
                surfaceID: binding.surfaceID,
                kind: binding.kind,
                displayCommand: argv.joined(separator: " "),
                argv: argv,
                sessionID: binding.sessionID ?? argv.last,
                trust: binding.trust,
                requiresConfirmation: binding.trust != .trusted
            )
        case .custom:
            return ResumeCommandPlan(
                surfaceID: binding.surfaceID,
                kind: binding.kind,
                displayCommand: binding.command,
                argv: nil,
                agentName: binding.agentName,
                sessionID: binding.sessionID,
                trust: binding.trust,
                requiresConfirmation: true
            )
        }
    }

    private static func agentPlan(for binding: ResumeBinding) -> ResumeCommandPlan {
        guard let agentName = binding.agentName?.lowercased(),
              let sessionID = binding.sessionID,
              let argv = agentResumeArgv(agentName: agentName, sessionID: sessionID)
        else {
            return ResumeCommandPlan(
                surfaceID: binding.surfaceID,
                kind: binding.kind,
                displayCommand: binding.command,
                argv: nil,
                agentName: binding.agentName,
                sessionID: binding.sessionID,
                trust: binding.trust,
                requiresConfirmation: true
            )
        }

        return ResumeCommandPlan(
            surfaceID: binding.surfaceID,
            kind: binding.kind,
            displayCommand: argv.joined(separator: " "),
            argv: argv,
            agentName: binding.agentName,
            sessionID: binding.sessionID,
            trust: binding.trust,
            requiresConfirmation: binding.trust != .trusted
        )
    }

    /// The agent's own resume command, from its profile (`AgentProfile.resumeArguments`).
    ///
    /// Bare argv on purpose — the launch layer (`LibGhosttyTerminalHostView`) prepends the
    /// `balagan-agent` wrapper for any profiled agent, so resume runs through it and gets the same
    /// integration as a fresh launch (Claude's hooks, pi's extension, OpenCode's plugin), which then
    /// re-reports the session id on every start/resume and keeps resume precise per surface.
    private static func agentResumeArgv(agentName: String, sessionID: String) -> [String]? {
        if let argv = AgentProfiles.named(agentName)?.resumeArgv(sessionID: sessionID) {
            return argv
        }
        switch agentName {
        case "gemini":
            return ["gemini", "--resume", sessionID]
        default:
            return nil
        }
    }
}
