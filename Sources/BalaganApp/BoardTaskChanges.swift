import Foundation
import BalaganCore

/// The Changes pane's data: what each task's branch has changed, loaded by running git off the main
/// thread. See `TaskChangesLoader` (Core).
enum TaskChangesState: Equatable {
    case loaded(TaskChanges)
    case failed(String)
}

extension BoardViewModel {
    static let taskChangesQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.task-changes", qos: .userInitiated)

    /// The task's on-disk working directory: its worktree when that exists, else the project checkout.
    /// Path math and a stat only, so it's cheap on the main thread.
    func taskWorkingDirectory(_ task: TaskItem) -> String? {
        guard let project = project(for: task.projectID) else { return nil }
        if let branch = task.branchOrWorktree?.nilIfBlank {
            let worktree = GitWorktreeManager.worktreePath(
                worktreesDirectory: project.resolvedWorktreesDirectory,
                branch: branch
            )
            if FileManager.default.fileExists(atPath: worktree) {
                return worktree
            }
        }
        return task.repoPathOverride?.nilIfBlank ?? project.repoPath
    }

    func toggleChangesView() {
        guard selectedTask != nil else { return }
        showingChangesView.toggle()
        // One pane swaps in for the terminal at a time.
        if showingChangesView { showingReaderMode = false }
    }

    /// Reloads a task's changes. Overlapping requests for the same task collapse into the one in
    /// flight; the previous result stays on screen until the new one lands.
    func refreshTaskChanges(taskID: TaskItem.ID) {
        guard taskChangesRefreshing.contains(taskID) == false,
              let task = tasks.first(where: { $0.id == taskID }),
              let directory = taskWorkingDirectory(task)
        else {
            return
        }
        let baseBranch = project(for: task.projectID)?.effectiveDefaultBranch ?? "main"
        taskChangesRefreshing.insert(taskID)

        let work = { () -> TaskChangesState in
            switch TaskChangesLoader.load(worktree: directory, baseBranch: baseBranch) {
            case .success(let changes): return .loaded(changes)
            case .failure(.notARepository): return .failed("\(directory) isn't a git repository.")
            case .failure(.gitFailed(let message)): return .failed(message)
            }
        }
        let apply = { [weak self] (state: TaskChangesState) in
            guard let self else { return }
            self.taskChangesRefreshing.remove(taskID)
            if self.taskChanges[taskID] != state { self.taskChanges[taskID] = state }
        }
        // Snapshots need the first render to already hold the diff.
        if synchronousGitReads {
            apply(work())
            return
        }
        Self.taskChangesQueue.async {
            let state = work()
            DispatchQueue.main.async { apply(state) }
        }
    }

    /// An agent just stopped in this task — if its changes are on screen, they probably moved.
    func refreshVisibleChangesAfterAgentStopped(taskID: TaskItem.ID) {
        guard showingChangesView, selectedTaskID == taskID else { return }
        refreshTaskChanges(taskID: taskID)
    }
}
