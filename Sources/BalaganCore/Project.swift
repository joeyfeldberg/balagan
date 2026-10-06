import Foundation

public struct Project: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var repoPath: String
    public var defaultBranch: String?
    public var defaultAgentCommand: String?
    /// Folder where per-task git worktrees are created. Blank/nil → a sibling `<repo>-worktrees`.
    public var worktreesDirectory: String?
    /// Shell commands run in a freshly created worktree (e.g. installs, env copy). Blank/nil → none.
    public var setupCommands: String?
    /// The board's kanban columns, in order (user-editable). Defaults to the four built-in lanes.
    public var lanes: [Lane]
    /// Whether the project's task list is folded away in the sidebar.
    public var sidebarCollapsed: Bool
    /// Prompts offered only for this project's tasks, ahead of the global ones.
    public var savedPrompts: [SavedPrompt]

    public init(
        id: String,
        name: String,
        repoPath: String,
        defaultBranch: String? = nil,
        defaultAgentCommand: String? = nil,
        worktreesDirectory: String? = nil,
        setupCommands: String? = nil,
        lanes: [Lane] = Lane.defaults,
        sidebarCollapsed: Bool = false,
        savedPrompts: [SavedPrompt] = []
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.defaultBranch = defaultBranch
        self.defaultAgentCommand = defaultAgentCommand
        self.worktreesDirectory = worktreesDirectory
        self.setupCommands = setupCommands
        self.lanes = lanes.isEmpty ? Lane.defaults : lanes
        self.sidebarCollapsed = sidebarCollapsed
        self.savedPrompts = savedPrompts
    }

    enum CodingKeys: String, CodingKey {
        case id, name, repoPath, defaultBranch, defaultAgentCommand, worktreesDirectory, setupCommands, lanes, sidebarCollapsed, savedPrompts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        defaultAgentCommand = try container.decodeIfPresent(String.self, forKey: .defaultAgentCommand)
        worktreesDirectory = try container.decodeIfPresent(String.self, forKey: .worktreesDirectory)
        setupCommands = try container.decodeIfPresent(String.self, forKey: .setupCommands)
        // Migration: a board saved before per-board lanes (or with an empty list) gets the defaults.
        let decodedLanes = try container.decodeIfPresent([Lane].self, forKey: .lanes)
        lanes = (decodedLanes?.isEmpty == false) ? decodedLanes! : Lane.defaults
        sidebarCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        savedPrompts = try container.decodeIfPresent([SavedPrompt].self, forKey: .savedPrompts) ?? []
    }

    /// The effective worktrees folder: the configured value, or the default sibling folder.
    public var resolvedWorktreesDirectory: String {
        if let configured = worktreesDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           configured.isEmpty == false {
            return (configured as NSString).expandingTildeInPath
        }
        return Project.defaultWorktreesDirectory(forRepoPath: repoPath)
    }

    /// Default sibling worktrees folder, e.g. `/x/y/repo` → `/x/y/repo-worktrees`.
    public static func defaultWorktreesDirectory(forRepoPath repoPath: String) -> String {
        let expanded = (repoPath as NSString).expandingTildeInPath
        let trimmed = expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        return trimmed + "-worktrees"
    }
}

extension Project {
    public var effectiveDefaultBranch: String {
        defaultBranch ?? "main"
    }

    public var defaultAgentCommandTemplates: [String: String] {
        guard let defaultAgentCommand else {
            return [:]
        }

        return ["default": defaultAgentCommand]
    }
}
