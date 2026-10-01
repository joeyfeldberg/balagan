import Foundation

public enum Tmux {
    public static let defaultPrefix = "task"
    public static let defaultMaxSessionNameLength = 80

    public static func sessionName(
        forTaskID taskID: Task.ID,
        prefix: String = defaultPrefix,
        maxLength: Int = defaultMaxSessionNameLength
    ) -> String {
        let safePrefix = sanitizedComponent(prefix).isEmpty ? defaultPrefix : sanitizedComponent(prefix)
        let safeTaskID = sanitizedComponent(taskID)
        let stem = safeTaskID.isEmpty ? "untitled" : safeTaskID
        let candidate = "\(safePrefix)_\(stem)"

        guard candidate.count > maxLength else {
            return candidate
        }

        let digest = String(fnv1a64(taskID).prefix(12))
        let suffix = "_\(digest)"
        let stemBudget = max(maxLength - safePrefix.count - 1 - suffix.count, 1)
        let truncatedStem = String(stem.prefix(stemBudget)).trimmingCharacters(in: trimCharacters)
        return "\(safePrefix)_\(truncatedStem.isEmpty ? "untitled" : truncatedStem)\(suffix)"
    }

    public static func newSessionCommand(
        forTaskID taskID: Task.ID,
        cwd: String,
        prefix: String = defaultPrefix
    ) -> [String] {
        [
            "tmux",
            "new-session",
            "-A",
            "-s",
            sessionName(forTaskID: taskID, prefix: prefix),
            "-c",
            cwd,
        ]
    }

    public static func attachCommand(
        forTaskID taskID: Task.ID,
        prefix: String = defaultPrefix
    ) -> [String] {
        [
            "tmux",
            "attach",
            "-t",
            sessionName(forTaskID: taskID, prefix: prefix),
        ]
    }

    private static let trimCharacters = CharacterSet(charactersIn: "_-")

    private static func sanitizedComponent(_ value: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in value.lowercased().unicodeScalars {
            if isAllowedASCII(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = scalar == "_" || scalar == "-"
            } else if !previousWasSeparator {
                result.append("_")
                previousWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: trimCharacters)
    }

    private static func isAllowedASCII(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 45, 95:
            return true
        default:
            return false
        }
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
