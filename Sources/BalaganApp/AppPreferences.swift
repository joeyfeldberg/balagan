import Foundation
import BalaganCore

/// App-level preferences (this Mac, not the board) kept in UserDefaults, edited in Settings.
enum AppPreferences {
    enum Keys {
        static let defaultAgent = "defaultAgentForNewProjects"
        static let waitingBanners = "bannersWhenAgentWaits"
        static let finishedBanners = "bannersWhenAgentFinishes"
        /// The sidebar usage meter shows only each agent's tightest window.
        static let usageCompact = "usageMeterCompact"
        /// Global saved prompts, JSON (`SavedPrompts.encode`). Absent = the defaults.
        static let savedPrompts = "savedPrompts"
    }

    /// The agent a new project is pre-filled with.
    enum DefaultAgent: String, CaseIterable, Identifiable {
        case codex, claude, opencode, pi, none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude Code"
            case .opencode: return "OpenCode"
            case .pi: return "pi"
            case .none: return "None (plain shell)"
            }
        }

        var command: String? {
            switch self {
            case .codex: return AgentCommandDefaults.codex
            case .claude: return AgentCommandDefaults.claude
            case .opencode: return AgentCommandDefaults.opencode
            case .pi: return AgentCommandDefaults.pi
            case .none: return nil
            }
        }
    }

    static var defaultAgent: DefaultAgent {
        get {
            UserDefaults.standard.string(forKey: Keys.defaultAgent).flatMap(DefaultAgent.init(rawValue:))
                ?? (AgentCommandDefaults.preferred == AgentCommandDefaults.claude ? .claude : .codex)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.defaultAgent) }
    }

    /// "Waiting for your input" banners. The in-app waiting glyphs are unaffected.
    static var waitingBanners: Bool {
        get { UserDefaults.standard.object(forKey: Keys.waitingBanners) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.waitingBanners) }
    }

    /// "The agent finished" banners. The in-app "finished, unseen" dot is unaffected.
    static var finishedBanners: Bool {
        get { UserDefaults.standard.object(forKey: Keys.finishedBanners) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.finishedBanners) }
    }
}
