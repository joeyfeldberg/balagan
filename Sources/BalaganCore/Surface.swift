import Foundation

public struct Surface: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var workspaceID: Workspace.ID
    public var title: String
    public var kind: SurfaceKind
    public var cwd: String
    public var environment: [String: String]
    public var startupCommand: String?
    /// One-time provisioning commands to run on the FIRST launch only, in this surface's (worktree)
    /// directory — kept separate from `startupCommand` so it never re-runs on relaunch and never ends
    /// up executing in the project's main repo. Cleared once consumed (or when the worktree is removed).
    public var setupCommand: String?
    public var resumeBinding: ResumeBinding?
    public var scrollbackSnapshot: String?
    public var agentLaunchMetadata: AgentLaunchMetadata?
    /// Agent sessions this tab ran before its current one, newest first (`SessionHistory`). Optional
    /// so older saved boards decode.
    public var previousSessions: [SessionRecord]?

    public init(
        id: String,
        workspaceID: Workspace.ID,
        title: String,
        kind: SurfaceKind = .terminal,
        cwd: String,
        environment: [String: String] = [:],
        startupCommand: String? = nil,
        setupCommand: String? = nil,
        resumeBinding: ResumeBinding? = nil,
        scrollbackSnapshot: String? = nil,
        agentLaunchMetadata: AgentLaunchMetadata? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.kind = kind
        self.cwd = cwd
        self.environment = environment
        self.startupCommand = startupCommand
        self.setupCommand = setupCommand
        self.resumeBinding = resumeBinding
        self.scrollbackSnapshot = scrollbackSnapshot
        self.agentLaunchMetadata = agentLaunchMetadata
    }
}

public enum SurfaceKind: String, Codable, Equatable, Hashable, Sendable {
    case terminal
}

public struct AgentLaunchMetadata: Codable, Equatable, Hashable, Sendable {
    public var agentName: String
    public var startupCommand: String
    public var cwd: String
    public var launchedAtMs: Int64
    public var captureStartedAtMs: Int64
    public var wrapperPath: String?

    public init(
        agentName: String,
        startupCommand: String,
        cwd: String,
        launchedAtMs: Int64,
        captureStartedAtMs: Int64? = nil,
        wrapperPath: String? = nil
    ) {
        self.agentName = agentName
        self.startupCommand = startupCommand
        self.cwd = cwd
        self.launchedAtMs = launchedAtMs
        self.captureStartedAtMs = captureStartedAtMs ?? launchedAtMs
        self.wrapperPath = wrapperPath
    }
}

extension Surface {
    public func sanitizedEnvironment(
        from environment: [String: String],
        allowlist: Set<String> = EnvironmentSanitizer.defaultAllowlist
    ) -> [String: String] {
        EnvironmentSanitizer.sanitize(environment, allowlist: allowlist)
    }
}
