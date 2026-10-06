import Foundation

/// What a drop onto a terminal types: file paths escaped for the shell (the way Ghostty does it),
/// separated and followed by a space so you can keep typing. Agents like Claude Code turn a pasted
/// image path into an image attachment.
public enum TerminalDrop {
    /// Characters a shell would split or interpret, backslash-escaped.
    static let specials: Set<Character> = [" ", "\\", "'", "\"", "`", "$", "&", "*", "?", ";", "|", "<", ">", "(", ")", "{", "}", "[", "]", "#", "~", "!", "\t"]

    public static func escapedPath(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if specials.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    public static func pasteText(forPaths paths: [String]) -> String {
        guard paths.isEmpty == false else { return "" }
        return paths.map(escapedPath).joined(separator: " ") + " "
    }

    /// Where image data dropped without a file (e.g. dragged out of a browser) is saved, so it has a
    /// path to paste: `<root>/drops/drop-<timestamp>.<ext>`.
    public static func dropFile(root: String, extension ext: String, at date: Date = Date()) -> String {
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        return root + "/drops/drop-\(stamp).\(ext)"
    }
}
