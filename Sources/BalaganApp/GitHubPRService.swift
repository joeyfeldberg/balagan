import Foundation
import BalaganCore

/// Fetches a task branch's pull request (state, CI checks, comments, reviews) by shelling out to the
/// GitHub CLI (`gh`), reusing the user's existing `gh` auth. Blocking; callers run it off the main
/// thread. Observe-only — it never creates or mutates anything.
enum GitHubPRService {
    enum Outcome: Sendable {
        case pr(TaskPullRequest)     // a PR exists for the branch
        case noPR                    // gh ran fine, but the branch has no PR
        case unavailable(String)     // gh missing / not authed / errored — reason for diagnostics
    }

    /// Common install locations, since a Finder-launched `.app` doesn't inherit the shell PATH that
    /// has `/opt/homebrew/bin` etc. Checked in order; first executable wins.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        "\(NSHomeDirectory())/.local/bin/gh",
    ]

    /// Resolved once per session — install location is stable and the lookup can touch a login shell.
    static let ghPath: String? = {
        let fileManager = FileManager.default
        if let direct = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return direct
        }
        // Last resort: ask a login shell (loads the user's PATH).
        return loginShellWhichGh()
    }()

    static var isAvailable: Bool { ghPath != nil }

    /// Fetches the PR for `branch` in the repository at `repoPath`. Blocking.
    static func fetch(repoPath: String, branch: String) -> Outcome {
        guard let ghPath else {
            return .unavailable("gh not found")
        }
        guard branch.isEmpty == false else {
            return .noPR
        }

        let result = run(
            ghPath,
            ["pr", "view", branch, "--json", GitHubPRStatusParser.ghViewFields],
            currentDirectory: repoPath
        )

        guard result.status == 0 else {
            let stderr = result.stderr.lowercased()
            // gh exits non-zero both for "no PR" and for real errors; disambiguate on the message.
            if stderr.contains("no pull requests found") || stderr.contains("no open pull requests") {
                return .noPR
            }
            if stderr.contains("authentication") || stderr.contains("gh auth login") {
                return .unavailable("gh not authenticated")
            }
            return .unavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard var pr = GitHubPRStatusParser.pullRequest(fromViewJSON: Data(result.stdout.utf8)) else {
            return .noPR
        }
        // Inline code-review comments aren't available via `gh pr view --json`; fetch them from the
        // REST endpoint. Best-effort — a failure just means no inline comments, not a failed PR.
        pr.reviewComments = fetchReviewComments(ghPath: ghPath, prURL: pr.url, repoPath: repoPath)
        return .pr(pr)
    }

    private static func fetchReviewComments(ghPath: String, prURL: String, repoPath: String) -> [PRReviewComment] {
        guard let (owner, repo, number) = parseOwnerRepoNumber(fromURL: prURL) else { return [] }
        let result = run(
            ghPath,
            ["api", "repos/\(owner)/\(repo)/pulls/\(number)/comments?per_page=100"],
            currentDirectory: repoPath
        )
        guard result.status == 0 else { return [] }
        return GitHubPRStatusParser.reviewComments(fromAPIJSON: Data(result.stdout.utf8))
    }

    /// Extracts (owner, repo, number) from a PR URL like `https://github.com/owner/repo/pull/128`.
    static func parseOwnerRepoNumber(fromURL url: String) -> (String, String, Int)? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        // ["owner", "repo", "pull", "128"]
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        return (parts[0], parts[1], number)
    }

    // MARK: - Process plumbing

    private struct RunResult { let status: Int32; let stdout: String; let stderr: String }

    private static func run(_ launchPath: String, _ arguments: [String], currentDirectory: String?) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        // Give gh a PATH so its git/credential-helper subprocesses resolve even under a bare app env.
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = [environment["PATH"], extraPath].compactMap { $0 }.joined(separator: ":")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return RunResult(status: -1, stdout: "", stderr: "failed to launch \(launchPath): \(error)")
        }

        // Read before waiting so a large payload can't deadlock on a full pipe buffer.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func loginShellWhichGh() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = run(shell, ["-lc", "command -v gh"], currentDirectory: nil)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status == 0 && path.isEmpty == false) ? path : nil
    }
}
