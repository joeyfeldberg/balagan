import Foundation

/// One changed file in a task's diff, as the Changes pane shows it.
public struct DiffFile: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case added, modified, deleted, renamed, untracked

        /// The one-letter badge in the file list.
        public var letter: String {
            switch self {
            case .added: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .renamed: return "R"
            case .untracked: return "U"
            }
        }
    }

    /// The file's current path (the new side). For a deletion, the path it had.
    public var path: String
    /// The previous path, for a rename.
    public var oldPath: String?
    public var status: Status
    public var isBinary: Bool
    public var hunks: [DiffHunk]
    /// Whether the file has changes not yet committed (so the agent may still be working on it).
    public var isUncommitted: Bool

    public var id: String { path }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public init(
        path: String,
        oldPath: String? = nil,
        status: Status,
        isBinary: Bool = false,
        hunks: [DiffHunk] = [],
        isUncommitted: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
        self.isUncommitted = isUncommitted
    }

    /// The last path component, for the list's bold name.
    public var fileName: String { (path as NSString).lastPathComponent }

    /// The containing directory ("" at the repo root), for the list's dimmed prefix.
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

public struct DiffHunk: Equatable, Sendable {
    /// The `@@ -a,b +c,d @@ context` line, as git wrote it.
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context, added, removed
    }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Git's "\ No newline at end of file" followed this line.
    public var missingNewline: Bool

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, missingNewline: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.missingNewline = missingNewline
    }
}

/// Parses `git diff` unified output (run with `--no-color --no-ext-diff`, and ideally
/// `-c core.quotePath=false`) into `DiffFile`s.
public enum GitDiffParser {
    public static func parse(_ output: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let finished = current { files.append(finished) }
            current = nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                let (a, b) = pathsFromDiffGitLine(line)
                current = DiffFile(path: b ?? a ?? "", status: .modified)
                continue
            }
            guard current != nil else { continue }

            if hunk == nil || line.hasPrefix("@@") {
                // Extended header lines (before the first hunk).
                if line.hasPrefix("@@") {
                    flushHunk()
                    let (oldStart, newStart) = hunkStarts(line)
                    oldLine = oldStart
                    newLine = newStart
                    hunk = DiffHunk(header: line, lines: [])
                } else if line.hasPrefix("new file mode") {
                    current?.status = .added
                } else if line.hasPrefix("deleted file mode") {
                    current?.status = .deleted
                } else if line.hasPrefix("rename from ") {
                    current?.oldPath = String(line.dropFirst("rename from ".count))
                    current?.status = .renamed
                } else if line.hasPrefix("rename to ") {
                    current?.path = String(line.dropFirst("rename to ".count))
                } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    current?.isBinary = true
                } else if line.hasPrefix("+++ "), let path = strippedPrefix(String(line.dropFirst(4))) {
                    current?.path = path
                } else if line.hasPrefix("--- "), current?.status == .deleted,
                          let path = strippedPrefix(String(line.dropFirst(4))) {
                    current?.path = path
                }
                continue
            }

            // Inside a hunk.
            if line.hasPrefix("+") {
                hunk?.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunk?.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                hunk?.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                if var last = hunk?.lines.popLast() {
                    last.missingNewline = true
                    hunk?.lines.append(last)
                }
            } else if line.isEmpty {
                // The trailing newline of the whole output; a real empty context line is " ".
                continue
            }
        }
        flushFile()
        return files
    }

    /// `diff --git a/x b/y` → ("x", "y"). Paths with spaces are ambiguous here, so the `+++`/`---`
    /// and `rename` lines, when present, overwrite this first guess.
    private static func pathsFromDiffGitLine(_ line: String) -> (String?, String?) {
        let rest = String(line.dropFirst("diff --git ".count))
        guard let range = rest.range(of: " b/", options: .backwards) else { return (nil, nil) }
        let a = String(rest[rest.startIndex..<range.lowerBound])
        let b = String(rest[range.upperBound...])
        return (a.hasPrefix("a/") ? String(a.dropFirst(2)) : a, b)
    }

    /// `a/path` / `b/path` → `path`; `/dev/null` → nil.
    private static func strippedPrefix(_ raw: String) -> String? {
        let path = raw.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? raw
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// `@@ -12,5 +14,7 @@` → (12, 14).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            let number = token.dropFirst().split(separator: ",").first.flatMap { Int($0) }
            return number ?? 1
        }
        let oldToken = parts.first { $0.hasPrefix("-") }
        let newToken = parts.first { $0.hasPrefix("+") }
        return (start(oldToken), start(newToken))
    }

    /// An untracked file shown as all-added lines. `contents` nil = unreadable or binary.
    public static func untrackedFile(path: String, contents: String?) -> DiffFile {
        guard let contents else {
            return DiffFile(path: path, status: .untracked, isBinary: true, isUncommitted: true)
        }
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
        let missingNewline = contents.isEmpty == false && contents.hasSuffix("\n") == false
        if contents.hasSuffix("\n") { lines.removeLast() }
        let diffLines = lines.enumerated().map { index, text in
            DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: index + 1)
        }
        var hunk = DiffHunk(header: "@@ -0,0 +1,\(diffLines.count) @@", lines: diffLines)
        if missingNewline, hunk.lines.isEmpty == false { hunk.lines[hunk.lines.count - 1].missingNewline = true }
        return DiffFile(path: path, status: .untracked, hunks: diffLines.isEmpty ? [] : [hunk], isUncommitted: true)
    }
}
