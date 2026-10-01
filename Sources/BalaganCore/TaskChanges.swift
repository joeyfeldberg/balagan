import Foundation

/// What a task's branch has changed, for the Changes pane: every file that differs between the
/// worktree (committed *and* uncommitted work, plus untracked files) and the point where the branch
/// left its base.
public struct TaskChanges: Equatable, Sendable {
    /// The branch compared against ("main", "origin/main"), or nil when only uncommitted changes are
    /// shown (the task works directly on its base branch).
    public var baseName: String?
    /// Commits on the branch since it left the base.
    public var commitsAhead: Int
    public var files: [DiffFile]
    /// The diff was too large and got cut off; the tail files are missing.
    public var isTruncated: Bool

    public init(baseName: String?, commitsAhead: Int, files: [DiffFile], isTruncated: Bool = false) {
        self.baseName = baseName
        self.commitsAhead = commitsAhead
        self.files = files
        self.isTruncated = isTruncated
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    public var uncommittedCount: Int { files.filter(\.isUncommitted).count }
}

/// Loads `TaskChanges` by running git in a worktree. Synchronous and blocking — call it off the main
/// thread. Read-only: it never writes to the repository.
public enum TaskChangesLoader {
    public enum Failure: Error, Equatable, Sendable {
        case notARepository
        case gitFailed(String)
    }

    /// Diff output beyond this is dropped (a vendored-dependency commit can be hundreds of MB).
    static let maxDiffBytes = 8 * 1024 * 1024
    /// Untracked files are read into the diff up to this many, and each up to `maxUntrackedBytes`.
    static let maxUntrackedFiles = 200
    static let maxUntrackedBytes = 512 * 1024

    public static func load(worktree: String, baseBranch: String) -> Result<TaskChanges, Failure> {
        guard run(["rev-parse", "--is-inside-work-tree"], in: worktree)?.trimmed == "true" else {
            return .failure(.notARepository)
        }

        // Compare against where the branch left its base. On the base branch itself (a task that
        // works "on main"), there is no branch to compare — show what's uncommitted.
        let currentBranch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree)?.trimmed
        var baseName: String?
        var mergeBase = "HEAD"
        if currentBranch != baseBranch {
            for candidate in [baseBranch, "origin/\(baseBranch)"] {
                if let sha = run(["merge-base", "HEAD", candidate], in: worktree)?.trimmed, sha.isEmpty == false {
                    baseName = candidate
                    mergeBase = sha
                    break
                }
            }
        }
        // A repo with no commits yet has no HEAD to diff against.
        let hasHead = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree) != nil

        let commitsAhead = baseName == nil
            ? 0
            : Int(run(["rev-list", "--count", "\(mergeBase)..HEAD"], in: worktree)?.trimmed ?? "") ?? 0

        var files: [DiffFile] = []
        var truncated = false
        if hasHead {
            guard let diff = run(
                ["diff", "--no-color", "--no-ext-diff", "--find-renames", mergeBase],
                in: worktree,
                limit: maxDiffBytes,
                truncated: &truncated
            ) else {
                return .failure(.gitFailed("git diff failed"))
            }
            files = GitDiffParser.parse(diff)
        }

        // Which of those have uncommitted edits (vs HEAD), so the list can mark work in progress.
        let dirty = hasHead
            ? Set((run(["diff", "--name-only", "-z", "HEAD"], in: worktree) ?? "").nulSeparated)
            : []
        for index in files.indices where dirty.contains(files[index].path) {
            files[index].isUncommitted = true
        }

        let untracked = (run(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree) ?? "").nulSeparated
        for path in untracked.prefix(maxUntrackedFiles) {
            files.append(GitDiffParser.untrackedFile(path: path, contents: readText(worktree, path)))
        }
        if untracked.count > maxUntrackedFiles { truncated = true }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return .success(TaskChanges(baseName: baseName, commitsAhead: commitsAhead, files: files, isTruncated: truncated))
    }

    /// A text file's contents, or nil if it's binary, unreadable, or larger than the cap.
    private static func readText(_ root: String, _ path: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // `read` returns nil at EOF, so an empty file comes back as nil data — that's "", not binary.
        let data = (try? handle.read(upToCount: maxUntrackedBytes + 1)) ?? Data()
        guard data.count <= maxUntrackedBytes, data.contains(0) == false else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - git

    private static func run(_ arguments: [String], in directory: String) -> String? {
        var ignored = false
        return run(arguments, in: directory, limit: maxDiffBytes, truncated: &ignored)
    }

    /// Runs git and returns stdout, or nil on a non-zero exit. Reads the pipe *before* waiting, so a
    /// large diff can't fill the pipe buffer and deadlock the child.
    private static func run(_ arguments: [String], in directory: String, limit: Int, truncated: inout Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // quotePath=false keeps non-ASCII paths readable instead of octal-escaped.
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"   // never take index.lock while an agent is committing
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        var data = Data()
        let handle = stdout.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 64 * 1024), chunk.isEmpty == false {
            if data.count < limit {
                data.append(chunk.prefix(limit - data.count))
            } else {
                truncated = true
            }
        }
        if data.count >= limit { truncated = true }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nulSeparated: [String] { split(separator: "\0").map(String.init) }
}
