import Foundation

public typealias ResumeBindingKind = ResumeKind
public typealias ResumeTrustStatus = ResumeTrust

public struct ResumeBinding: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var taskID: Task.ID?
    public var workspaceID: Workspace.ID?
    public var surfaceID: Surface.ID
    public var kind: ResumeKind
    public var agentName: String?
    public var sessionID: String?
    public var command: String
    public var trust: ResumeTrust
    public var source: ResumeBindingSource
    public var pid: Int32?
    public var executablePath: String?
    public var argv: [String]
    public var cwd: String?
    public var capturedAt: Date?
    public var captureUpdatedAt: Date?
    public var wasRunning: Bool
    public var isRestorable: Bool
    public var isStale: Bool
    public var autoResume: Bool
    public var transcriptPath: String?
    public var sanitizedEnvironment: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        taskID: Task.ID? = nil,
        workspaceID: Workspace.ID? = nil,
        surfaceID: Surface.ID,
        kind: ResumeKind,
        agentName: String? = nil,
        sessionID: String? = nil,
        command: String,
        trust: ResumeTrust = .untrusted,
        source: ResumeBindingSource = .manual,
        pid: Int32? = nil,
        executablePath: String? = nil,
        argv: [String] = [],
        cwd: String? = nil,
        capturedAt: Date? = nil,
        captureUpdatedAt: Date? = nil,
        wasRunning: Bool = false,
        isRestorable: Bool = true,
        isStale: Bool = false,
        autoResume: Bool = false,
        transcriptPath: String? = nil,
        sanitizedEnvironment: [String: String] = [:],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.kind = kind
        self.agentName = agentName
        self.sessionID = sessionID
        self.command = command
        self.trust = trust
        self.source = source
        self.pid = pid
        self.executablePath = executablePath
        self.argv = argv
        self.cwd = cwd
        self.capturedAt = capturedAt
        self.captureUpdatedAt = captureUpdatedAt
        self.wasRunning = wasRunning
        self.isRestorable = isRestorable
        self.isStale = isStale
        self.autoResume = autoResume
        self.transcriptPath = transcriptPath
        self.sanitizedEnvironment = sanitizedEnvironment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case workspaceID
        case surfaceID
        case kind
        case agentName
        case sessionID
        case command
        case trust
        case source
        case pid
        case executablePath
        case argv
        case cwd
        case capturedAt
        case captureUpdatedAt
        case wasRunning
        case isRestorable
        case isStale
        case autoResume
        case transcriptPath
        case sanitizedEnvironment
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.taskID = try container.decodeIfPresent(Task.ID.self, forKey: .taskID)
        self.workspaceID = try container.decodeIfPresent(Workspace.ID.self, forKey: .workspaceID)
        self.surfaceID = try container.decode(Surface.ID.self, forKey: .surfaceID)
        self.kind = try container.decode(ResumeKind.self, forKey: .kind)
        self.agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        self.command = try container.decode(String.self, forKey: .command)
        self.trust = try container.decodeIfPresent(ResumeTrust.self, forKey: .trust) ?? .untrusted
        self.source = try container.decodeIfPresent(ResumeBindingSource.self, forKey: .source) ?? .manual
        self.pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        self.executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        self.argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        self.captureUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .captureUpdatedAt)
        self.wasRunning = try container.decodeIfPresent(Bool.self, forKey: .wasRunning) ?? false
        self.isRestorable = try container.decodeIfPresent(Bool.self, forKey: .isRestorable) ?? true
        self.isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        self.autoResume = try container.decodeIfPresent(Bool.self, forKey: .autoResume) ?? false
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.sanitizedEnvironment = try container.decodeIfPresent(
            [String: String].self,
            forKey: .sanitizedEnvironment
        ) ?? [:]
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
    }
}

public enum ResumeBindingSource: String, Codable, Equatable, Hashable, Sendable {
    case agentHook = "agent-hook"
    case manual
    case processDetected = "process-detected"
    case appSnapshot = "app-snapshot"
    case unknown
}

public enum ResumeKind: String, Codable, Equatable, Hashable, Sendable {
    case agent
    case tmux
    case custom
}

public enum ResumeTrust: String, Codable, Equatable, Hashable, Sendable {
    case trusted
    case untrusted
}

extension ResumeBinding {
    public var isTrusted: Bool {
        trust == .trusted
    }

    public var isCaptured: Bool {
        switch source {
        case .agentHook, .processDetected, .appSnapshot:
            return true
        case .manual, .unknown:
            return false
        }
    }

    public var allowsAutomaticLaunch: Bool {
        isTrusted && isCaptured && autoResume && isRestorable && !isStale
    }
}
