import XCTest
@testable import BalaganCore

final class GitWorktreeManagerTests: XCTestCase {
    func testFolderNameFlattensUnsafeCharacters() {
        XCTAssertEqual(GitWorktreeManager.worktreeFolderName(for: "feature/login"), "feature-login")
        XCTAssertEqual(GitWorktreeManager.worktreeFolderName(for: "fix: bug"), "fix--bug")
        XCTAssertEqual(GitWorktreeManager.worktreeFolderName(for: "main"), "main")
    }

    func testDefaultWorktreesDirectoryIsSiblingFolder() {
        XCTAssertEqual(
            Project.defaultWorktreesDirectory(forRepoPath: "/Users/x/repos/app"),
            "/Users/x/repos/app-worktrees"
        )
        XCTAssertEqual(
            Project.defaultWorktreesDirectory(forRepoPath: "/Users/x/repos/app/"),
            "/Users/x/repos/app-worktrees"
        )
    }

    func testEnsureWorktreeCreatesBranchWorktreeAndReusesIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("balagan-worktree-test-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let worktrees = root.appendingPathComponent("repo-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Minimal git repo with one commit so worktrees can be created.
        try runGit(["init", "-q"], in: repo)
        try runGit(["config", "user.email", "test@example.com"], in: repo)
        try runGit(["config", "user.name", "Test"], in: repo)
        try runGit(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)

        let created = GitWorktreeManager.ensureWorktree(
            repoPath: repo.path,
            worktreesDirectory: worktrees.path,
            branch: "feature/login",
            baseBranch: nil
        )

        let expectedPath = worktrees.appendingPathComponent("feature-login").path
        XCTAssertEqual(created?.path, expectedPath)
        XCTAssertEqual(created?.created, true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        // The branch was created.
        XCTAssertNoThrow(try runGit(["show-ref", "--verify", "--quiet", "refs/heads/feature/login"], in: repo))

        // A fresh worktree is clean.
        XCTAssertTrue(GitWorktreeManager.isWorktreeClean(at: expectedPath))

        // A second call reuses the same worktree (created == false).
        let reused = GitWorktreeManager.ensureWorktree(
            repoPath: repo.path,
            worktreesDirectory: worktrees.path,
            branch: "feature/login",
            baseBranch: nil
        )
        XCTAssertEqual(reused?.path, expectedPath)
        XCTAssertEqual(reused?.created, false)

        // An untracked file makes it dirty.
        try "x".write(toFile: (expectedPath as NSString).appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(GitWorktreeManager.isWorktreeClean(at: expectedPath))

        // Force removal succeeds and deletes the directory; the branch survives.
        XCTAssertTrue(GitWorktreeManager.removeWorktree(repoPath: repo.path, worktreePath: expectedPath, force: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
        XCTAssertNoThrow(try runGit(["show-ref", "--verify", "--quiet", "refs/heads/feature/login"], in: repo))
    }

    func testEnsureWorktreeReturnsNilOutsideGitRepo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("balagan-nonrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = GitWorktreeManager.ensureWorktree(
            repoPath: dir.path,
            worktreesDirectory: dir.appendingPathComponent("wt").path,
            branch: "feature",
            baseBranch: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - Base-branch resolution (detect default, prefer origin/<default>, never the current HEAD)

    func testDetectsDefaultBranchFromOriginHead() throws {
        try skipIfNoGit()
        let (repo, root) = try makeRepoWithOrigin()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(GitWorktreeManager.detectDefaultBranch(repo: repo.path), "main")
    }

    func testDetectDefaultBranchIsNilWithoutRemote() throws {
        try skipIfNoGit()
        let (repo, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GitWorktreeManager.detectDefaultBranch(repo: repo.path))
    }

    func testResolveBaseRefPrefersOriginThenLocalThenHead() throws {
        try skipIfNoGit()
        let (originRepo, originRoot) = try makeRepoWithOrigin()
        defer { try? FileManager.default.removeItem(at: originRoot) }
        // origin/main exists → prefer the remote-tracking ref, even with no requested base.
        XCTAssertEqual(GitWorktreeManager.resolveBaseRef(repo: originRepo.path, requestedBase: nil), "origin/main")
        XCTAssertEqual(GitWorktreeManager.resolveBaseRef(repo: originRepo.path, requestedBase: "main"), "origin/main")

        let (localRepo, localRoot) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: localRoot) }
        try runGit(["branch", "-M", "main"], in: localRepo)
        // No remote → fall back to the local branch when explicitly requested, else HEAD.
        XCTAssertEqual(GitWorktreeManager.resolveBaseRef(repo: localRepo.path, requestedBase: "main"), "main")
        XCTAssertEqual(GitWorktreeManager.resolveBaseRef(repo: localRepo.path, requestedBase: nil), "HEAD")
    }

    func testNewBranchForksFromOriginDefaultNotLocalHead() throws {
        try skipIfNoGit()
        let (repo, root) = try makeRepoWithOrigin()
        defer { try? FileManager.default.removeItem(at: root) }

        let originMain = try gitOutput(["rev-parse", "origin/main"], in: repo)
        // Advance LOCAL main past origin/main, and check out a different branch as HEAD.
        try runGit(["commit", "-q", "--allow-empty", "-m", "local-ahead"], in: repo)
        let localMain = try gitOutput(["rev-parse", "main"], in: repo)
        XCTAssertNotEqual(originMain, localMain)
        try runGit(["checkout", "-q", "-b", "some-feature"], in: repo)

        let worktrees = root.appendingPathComponent("repo-worktrees", isDirectory: true)
        let result = GitWorktreeManager.ensureWorktree(
            repoPath: repo.path,
            worktreesDirectory: worktrees.path,
            branch: "task-branch",
            baseBranch: nil // unset → must resolve to origin/main, not the current HEAD (some-feature)
        )
        let worktreePath = try XCTUnwrap(result?.path)
        let worktreeHead = try gitOutput(["rev-parse", "HEAD"], in: URL(fileURLWithPath: worktreePath))
        XCTAssertEqual(worktreeHead, originMain, "new branch should fork from origin/main")
        XCTAssertNotEqual(worktreeHead, localMain, "new branch must not fork from the current HEAD")
    }

    // MARK: - Safe branch deletion

    func testDeleteBranchIfMergedDeletesMergedAndKeepsUnmerged() throws {
        try skipIfNoGit()
        let (repo, root) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["branch", "-M", "main"], in: repo)

        // A branch with no commits of its own is fully merged → safe delete succeeds.
        try runGit(["branch", "merged-branch"], in: repo)
        XCTAssertTrue(GitWorktreeManager.deleteBranchIfMerged(repoPath: repo.path, branch: "merged-branch"))
        XCTAssertThrowsError(try runGit(["show-ref", "--verify", "--quiet", "refs/heads/merged-branch"], in: repo))

        // A branch with its own unmerged commit must be kept (git branch -d refuses).
        try runGit(["checkout", "-q", "-b", "wip-branch"], in: repo)
        try runGit(["commit", "-q", "--allow-empty", "-m", "wip work"], in: repo)
        try runGit(["checkout", "-q", "main"], in: repo)
        XCTAssertFalse(GitWorktreeManager.deleteBranchIfMerged(repoPath: repo.path, branch: "wip-branch"))
        XCTAssertNoThrow(try runGit(["show-ref", "--verify", "--quiet", "refs/heads/wip-branch"], in: repo))

        // A blank or unknown branch name is a no-op false.
        XCTAssertFalse(GitWorktreeManager.deleteBranchIfMerged(repoPath: repo.path, branch: "   "))
        XCTAssertFalse(GitWorktreeManager.deleteBranchIfMerged(repoPath: repo.path, branch: "does-not-exist"))
    }

    // MARK: - Helpers

    private func skipIfNoGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git is not available")
        }
    }

    /// A fresh repo with one commit on `main`, no remote. Returns (repo, root-to-clean-up).
    private func makeRepo() throws -> (repo: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("balagan-wt-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: repo)
        try runGit(["config", "user.email", "test@example.com"], in: repo)
        try runGit(["config", "user.name", "Test"], in: repo)
        try runGit(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        return (repo, root)
    }

    /// A repo whose `origin` remote has its `HEAD` pointing at `main` (so default-branch detection works).
    private func makeRepoWithOrigin() throws -> (repo: URL, root: URL) {
        let (repo, root) = try makeRepo()
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", "-q"], in: origin)
        try runGit(["branch", "-M", "main"], in: repo)
        try runGit(["remote", "add", "origin", origin.path], in: repo)
        try runGit(["push", "-q", "-u", "origin", "main"], in: repo)
        try runGit(["remote", "set-head", "origin", "main"], in: repo)
        return (repo, root)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        try gitOutput(arguments, in: directory)
    }

    @discardableResult
    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
