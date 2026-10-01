import Foundation
import BalaganCore

/// View-model side of PR/CI tracking: figures out which tasks can have a PR, kicks off `gh` fetches
/// off the main thread, and applies the results. See `GitHubPRService` (fetch) and
/// `AppPullRequestPolling` (the timer that drives `refreshAllPullRequests`).
extension BoardViewModel {
    /// Serial background queue for `gh` calls — keeps fetches off the main thread and off each other's
    /// backs (a handful of ~sub-second calls per poll; no need to fan out and hammer the API).
    static let pullRequestFetchQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.pr-fetch")

    /// The repo a task's PR lives in: the task's override, else its project's repo.
    func pullRequestRepoPath(for task: TaskItem) -> String? {
        if let override = task.repoPathOverride?.nilIfBlank {
            return override
        }
        return project(for: task.projectID)?.repoPath
    }

    /// Tasks that have a dedicated branch (so a PR is possible). Tasks working on main (blank branch)
    /// are skipped — there's no per-task branch to resolve a PR from.
    private func pullRequestTrackableTasks() -> [(taskID: TaskItem.ID, repoPath: String, branch: String)] {
        tasks.compactMap { task in
            guard task.isProjectTerminals == false,
                  let branch = task.branchOrWorktree?.nilIfBlank,
                  let repoPath = pullRequestRepoPath(for: task)
            else {
                return nil
            }
            return (task.id, repoPath, branch)
        }
    }

    /// Whether the task tracks a PR (has a branch) — gates the header PR panel / card badge slot.
    func tracksPullRequest(_ task: TaskItem) -> Bool {
        task.isProjectTerminals == false && task.branchOrWorktree?.nilIfBlank != nil
    }

    /// Refetch every trackable task's PR (the poll + "refresh all" entry point).
    func refreshAllPullRequests() {
        guard pullRequestTrackingEnabled else { return }
        guard GitHubPRService.isAvailable else {
            if pullRequestsUnavailableReason == nil {
                pullRequestsUnavailableReason = "GitHub CLI (gh) not found"
            }
            return
        }
        pullRequestsUnavailableReason = nil
        for item in pullRequestTrackableTasks() {
            startPullRequestFetch(taskID: item.taskID, repoPath: item.repoPath, branch: item.branch)
        }
    }

    /// Refetch a single task's PR (manual refresh button / on task open).
    func refreshPullRequest(taskID: TaskItem.ID) {
        guard pullRequestTrackingEnabled else { return }
        guard let task = tasks.first(where: { $0.id == taskID }),
              let branch = task.branchOrWorktree?.nilIfBlank,
              let repoPath = pullRequestRepoPath(for: task)
        else {
            return
        }
        startPullRequestFetch(taskID: taskID, repoPath: repoPath, branch: branch)
    }

    /// Test-only: seeds a representative PR onto the first branch-bearing task so the headless
    /// screenshot harness can capture the CI badge / header button (`BALAGAN_FAKE_PR=1`). Never
    /// called in normal runs.
    func seedFakePullRequestForSnapshot() {
        for taskID in pullRequestTrackableTasks().map(\.taskID) {
            pullRequests[taskID] = sampleSnapshotPullRequest
        }
    }

    private var sampleSnapshotPullRequest: TaskPullRequest {
        TaskPullRequest(
            number: 128,
            title: "Add right-click Sleep to put a task's tabs to sleep",
            url: "https://github.com/example/repo/pull/128",
            state: .open,
            isDraft: false,
            reviewDecision: "CHANGES_REQUESTED",
            checks: [
                CICheck(name: "build", state: .success, url: "https://x/build"),
                CICheck(name: "test", state: .failure, url: "https://x/test"),
                CICheck(name: "lint", state: .pending, url: nil),
            ],
            comments: [PRComment(author: "joeyfeldberg", body: "Ready for review — split the god file.", createdAt: "2026-07-15T10:00:00Z", url: "https://x/c1")],
            reviews: [PRReview(author: "octocat", state: "CHANGES_REQUESTED", body: "Please add a test for the rollup edge case.", submittedAt: "2026-07-15T11:00:00Z", url: "https://x/r1")]
        )
    }

    private func startPullRequestFetch(taskID: TaskItem.ID, repoPath: String, branch: String) {
        guard pullRequestsRefreshing.contains(taskID) == false else {
            return   // a fetch is already in flight for this task
        }
        pullRequestsRefreshing.insert(taskID)

        BoardViewModel.pullRequestFetchQueue.async { [weak self] in
            let outcome = GitHubPRService.fetch(repoPath: repoPath, branch: branch)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pullRequestsRefreshing.remove(taskID)
                switch outcome {
                case .pr(let pullRequest):
                    self.pullRequests[taskID] = pullRequest
                case .noPR:
                    self.pullRequests[taskID] = nil
                case .unavailable(let reason):
                    // Leave any previously-fetched PR in place; surface the reason for diagnostics.
                    self.pullRequestsUnavailableReason = reason.isEmpty ? "gh error" : reason
                    NSLog("Balagan PR fetch unavailable for \(taskID): \(reason)")
                }
            }
        }
    }
}
