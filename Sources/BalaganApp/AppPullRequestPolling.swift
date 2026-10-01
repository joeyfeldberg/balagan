import AppKit
import BalaganCore

extension BalaganApplication {
    /// Poll GitHub (via `gh`) every 60 s for the PR/CI status of tasks that have a branch, plus an
    /// immediate first fetch. Each tick refetches all trackable tasks; in-flight ones are deduped by
    /// `pullRequestsRefreshing`. Not started in `--ui-test-mode` (it shells out / hits the network).
    @MainActor
    func startPullRequestPolling() {
        guard GitHubPRService.isAvailable else {
            viewModel?.pullRequestsUnavailableReason = "GitHub CLI (gh) not found"
            return
        }
        viewModel?.refreshAllPullRequests()
        pullRequestPollTimer?.invalidate()
        pullRequestPollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel?.refreshAllPullRequests()
            }
        }
    }
}
