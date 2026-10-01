import Foundation

/// Shared heuristics for recognizing a fresh (non-resume) Balagan-launched Codex session, used by
/// both Codex session capture and the resume-launch policy.
enum CodexCommandHeuristics {
    static func snapshotContainsFreshCodexLaunch(_ snapshot: String) -> Bool {
        snapshot.localizedCaseInsensitiveContains("codex")
    }

    static func isFreshBalaganCodexCommand(_ startupCommand: String) -> Bool {
        let command = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [
            "balagan-agent codex",
            "balagan-agent' codex",
            "balagan-agent\" codex",
        ]

        for marker in markers {
            guard let range = command.range(of: marker) else {
                continue
            }
            let remainder = command[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                return true
            }
            let firstArgument = remainder.split(separator: " ", maxSplits: 1).first.map(String.init)
            return firstArgument != "resume"
        }

        return false
    }
}
