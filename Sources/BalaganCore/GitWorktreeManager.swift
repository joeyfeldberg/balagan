import Foundation

/// Creates / reuses git worktrees so each task can open its terminal in an isolated branch checkout
/// (the "Workspace" on a task). Every operation is best-effort: any failure — not a git repo, a git
/// error, an existing non-worktree path — returns `nil` so callers fall back to the main repo path.
public enum GitWorktreeManager {
    /// The outcome of resolving a worktree: its path, and whether this call created it (vs reused).
    public struct WorktreeResult: Equatable, Sendable {
        public let path: String
        public let created: Bool

        public init(path: String, created: Bool) {
            self.path = path
            self.created = created
        }
    }

    /// Ensures a worktree for `branch` exists under `worktreesDirectory` and returns its path plus
    /// whether it was just created. Reuses it if already present; otherwise creates the branch from a
    /// resolved base (the requested `baseBranch`, else the repo's detected default branch — preferring
    /// the remote-tracking `origin/<base>` so new work forks from the latest fetched default, then the
    /// local branch, then `HEAD`) and the worktree. Returns `nil` on any failure.
    public static func ensureWorktree(
        repoPath: String,
        worktreesDirectory: String,
        branch: String,
        baseBranch: String?
    ) -> WorktreeResult? {
        let repo = (repoPath as NSString).expandingTildeInPath
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchName.isEmpty == false else {
            return nil
        }

        // Only operate inside a real git work tree.
        guard runGit(["-C", repo, "rev-parse", "--is-inside-work-tree"], cwd: repo)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }

        let worktreePath = self.worktreePath(worktreesDirectory: worktreesDirectory, branch: branchName)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory) {
            // Reuse an existing worktree; bail on a non-directory collision.
            return isDirectory.boolValue ? WorktreeResult(path: worktreePath, created: false) : nil
        }

        try? FileManager.default.createDirectory(
            atPath: (worktreesDirectory as NSString).expandingTildeInPath,
            withIntermediateDirectories: true
        )

        let branchExists = runGit(
            ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            cwd: repo
        ) != nil

        let addArguments: [String]
        if branchExists {
            addArguments = ["-C", repo, "worktree", "add", worktreePath, branchName]
        } else {
            let baseRef = resolveBaseRef(repo: repo, requestedBase: baseBranch)
            addArguments = ["-C", repo, "worktree", "add", "-b", branchName, worktreePath, baseRef]
        }

        guard runGit(addArguments, cwd: repo) != nil else {
            return nil
        }
        return WorktreeResult(path: worktreePath, created: true)
    }

    /// Resolves the start-point for a *new* branch. Uses the requested base if given, else the repo's
    /// detected default branch; and for whichever it is, prefers the remote-tracking ref `origin/<base>`
    /// (so new work forks from the latest fetched default rather than a possibly-stale local branch),
    /// then the local branch, then `HEAD`. Never branches off the currently-checked-out branch unless
    /// nothing better can be resolved.
    static func resolveBaseRef(repo: String, requestedBase: String?) -> String {
        let trimmed = requestedBase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmed?.isEmpty == false ? trimmed : nil) ?? detectDefaultBranch(repo: repo)
        guard let base else {
            return "HEAD"
        }
        if refExists(repo: repo, ref: "refs/remotes/origin/\(base)") {
            return "origin/\(base)"
        }
        if refExists(repo: repo, ref: "refs/heads/\(base)") {
            return base
        }
        return "HEAD"
    }

    /// The repo's default branch via `origin/HEAD` (e.g. "main" / "master"), or `nil` if undetermined
    /// (no remote, `origin/HEAD` unset). Run `git remote set-head origin -a` once to populate it.
    static func detectDefaultBranch(repo: String) -> String? {
        guard let raw = runGit(["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo)?
            .trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return nil
        }
        let prefix = "origin/"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    private static func refExists(repo: String, ref: String) -> Bool {
        runGit(["-C", repo, "show-ref", "--verify", "--quiet", ref], cwd: repo) != nil
    }

    /// The on-disk worktree path for a branch (without touching git).
    public static func worktreePath(worktreesDirectory: String, branch: String) -> String {
        let worktreeDir = (worktreesDirectory as NSString).expandingTildeInPath
        return (worktreeDir as NSString).appendingPathComponent(worktreeFolderName(for: branch))
    }

    /// Whether a worktree has no uncommitted or untracked changes. Returns `false` if the state can't
    /// be determined (so callers warn rather than silently discard work).
    public static func isWorktreeClean(at worktreePath: String) -> Bool {
        let path = (worktreePath as NSString).expandingTildeInPath
        guard let status = runGit(["-C", path, "status", "--porcelain"], cwd: path) else {
            return false
        }
        return status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Removes a worktree. With `force`, discards uncommitted/untracked changes. Returns success.
    /// The branch is left intact. Best-effort: prunes stale metadata afterward.
    @discardableResult
    public static func removeWorktree(repoPath: String, worktreePath: String, force: Bool) -> Bool {
        let repo = (repoPath as NSString).expandingTildeInPath
        let path = (worktreePath as NSString).expandingTildeInPath
        var arguments = ["-C", repo, "worktree", "remove", path]
        if force {
            arguments.append("--force")
        }
        let removed = runGit(arguments, cwd: repo) != nil
        runGit(["-C", repo, "worktree", "prune"], cwd: repo)
        return removed
    }

    /// Safely deletes a local branch with `git branch -d`, which refuses (non-zero exit) when the
    /// branch still has commits not merged into its upstream or HEAD — so this never discards unmerged
    /// work. Run *after* removing the worktree (a branch checked out in a worktree can't be deleted).
    /// Returns true only if the branch was actually deleted; false if it was kept (unmerged), absent,
    /// or still checked out elsewhere.
    @discardableResult
    public static func deleteBranchIfMerged(repoPath: String, branch: String) -> Bool {
        let repo = (repoPath as NSString).expandingTildeInPath
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchName.isEmpty == false else {
            return false
        }
        return runGit(["-C", repo, "branch", "-d", branchName], cwd: repo) != nil
    }

    /// Maps a branch name to a single safe folder name (flattening `/`, spaces, and `:`).
    public static func worktreeFolderName(for branch: String) -> String {
        let mapped = branch.map { character -> Character in
            (character == "/" || character == " " || character == ":") ? "-" : character
        }
        return String(mapped)
    }

    /// Runs git and returns stdout on success (exit 0), or `nil` on launch failure / non-zero exit.
    @discardableResult
    private static func runGit(_ arguments: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
