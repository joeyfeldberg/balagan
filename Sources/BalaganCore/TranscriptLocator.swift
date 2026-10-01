import Foundation

/// Locates an agent session's on-disk transcript (JSONL) from its session id.
///
/// Preferred source is the path captured at session start (`ResumeBinding.transcriptPath`); this
/// locator is the fallback for bindings recorded before capture existed, and the primary source for
/// Codex (whose rollout path is cheaper to find by filename than to thread through the capture).
/// Session ids are globally unique, so a filename match needs no cwd-slug derivation:
/// - Claude: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`
/// - Codex:  `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`
public struct TranscriptLocator: Sendable {
    public var claudeProjectsDirectoryURL: URL
    public var codexSessionsDirectoryURL: URL

    public init(claudeProjectsDirectoryURL: URL, codexSessionsDirectoryURL: URL) {
        self.claudeProjectsDirectoryURL = claudeProjectsDirectoryURL
        self.codexSessionsDirectoryURL = codexSessionsDirectoryURL
    }

    public static func `default`(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TranscriptLocator {
        TranscriptLocator(
            claudeProjectsDirectoryURL: homeDirectory.appendingPathComponent(".claude/projects"),
            codexSessionsDirectoryURL: homeDirectory.appendingPathComponent(".codex/sessions")
        )
    }

    /// Honors `BALAGAN_CODEX_CAPTURE_HOME` the same way `CodexSessionCapture.fromEnvironment` does.
    public static func fromEnvironment(_ environment: [String: String]) -> TranscriptLocator {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["BALAGAN_CODEX_CAPTURE_HOME"].map(URL.init(fileURLWithPath:)) ?? home
        return TranscriptLocator(
            claudeProjectsDirectoryURL: home.appendingPathComponent(".claude/projects"),
            codexSessionsDirectoryURL: codexHome.appendingPathComponent(".codex/sessions")
        )
    }

    /// Returns `storedPath` when it still exists on disk; otherwise searches the agent's session
    /// store for a transcript named by `sessionID`. An unknown agent searches both stores.
    public func resolve(agentName: String?, sessionID: String?, storedPath: String? = nil) -> String? {
        if let storedPath = storedPath?.nilIfBlank,
           FileManager.default.fileExists(atPath: storedPath) {
            return storedPath
        }
        guard let sessionID = sessionID?.nilIfBlank else {
            return nil
        }
        switch agentName?.lowercased() {
        case "claude":
            return claudeTranscriptPath(sessionID: sessionID)
        case "codex":
            return codexRolloutPath(sessionID: sessionID)
        default:
            return claudeTranscriptPath(sessionID: sessionID) ?? codexRolloutPath(sessionID: sessionID)
        }
    }

    private func claudeTranscriptPath(sessionID: String) -> String? {
        let projectDirectories = (try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in projectDirectories {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private func codexRolloutPath(sessionID: String) -> String? {
        let urls = FileManager.default.enumerator(
            at: codexSessionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []
        for url in urls where url.pathExtension == "jsonl" {
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix("-\(sessionID)") {
                return url.path
            }
        }
        return nil
    }
}
