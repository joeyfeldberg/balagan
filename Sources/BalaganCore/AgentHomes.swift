import Foundation

/// The agents' own data folders, resolved the way the agents themselves do, so session capture,
/// transcripts and usage all look where the agent actually writes.
public enum AgentHomes {
    /// Codex's folder: `$CODEX_HOME`, else `~/.codex`. `BALAGAN_CODEX_CAPTURE_HOME` (tests and smokes)
    /// stands in for the home directory and wins over both.
    public static func codex(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let captureHome = environment["BALAGAN_CODEX_CAPTURE_HOME"]?.nilIfBlank {
            return URL(fileURLWithPath: captureHome).appendingPathComponent(".codex")
        }
        if let codexHome = environment["CODEX_HOME"]?.nilIfBlank {
            return URL(fileURLWithPath: codexHome)
        }
        return homeDirectory.appendingPathComponent(".codex")
    }

    /// Claude Code's config folder: `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func claude(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configDirectory = environment["CLAUDE_CONFIG_DIR"]?.nilIfBlank {
            return URL(fileURLWithPath: configDirectory)
        }
        return homeDirectory.appendingPathComponent(".claude")
    }
}
