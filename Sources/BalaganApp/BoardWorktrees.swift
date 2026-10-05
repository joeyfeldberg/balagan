import Foundation
import BalaganCore

/// A task's worktree (its Workspace branch) and whether that worktree directory still exists on disk.
struct TaskWorktreeInfo: Equatable {
    let branch: String
    let path: String
    let exists: Bool
}

/// Git-worktree resolution and teardown for tasks, plus the one-time setup-command lifecycle.
/// Extracted from `BoardCRUD`.
extension BoardViewModel {
    /// Where a task's terminal should open, and how that was resolved.
    struct WorkingDirectoryResolution {
        /// The directory to open the terminal in.
        var cwd: String
        /// True when this call just created the worktree (so one-time setup commands run).
        var createdWorktree: Bool
        /// A branch/worktree was requested but git couldn't create it — `cwd` is the project's main
        /// checkout, so callers must NOT auto-run an agent there.
        var worktreeUnavailable: Bool
    }

    /// Resolves a task's terminal directory: a git worktree for its "Workspace" branch when set
    /// (created lazily in the live app via `worktreeResolver`), otherwise the project's repo. Also
    /// reports whether the worktree was just created (so setup commands run on first creation only).
    func resolveWorkingDirectory(
        forProject project: Project,
        repoPathOverride: String?,
        branchOrWorktree: String?
    ) -> WorkingDirectoryResolution {
        let fallback = repoPathOverride?.nilIfBlank ?? project.repoPath

        // No branch requested → the project's main checkout (intended; an agent may run here).
        guard let branch = (branchOrWorktree ?? "").nilIfBlank else {
            return WorkingDirectoryResolution(cwd: fallback, createdWorktree: false, worktreeUnavailable: false)
        }
        // No resolver (headless / tests) → use the repo path; not a failure worth surfacing.
        guard let resolver = worktreeResolver else {
            return WorkingDirectoryResolution(cwd: fallback, createdWorktree: false, worktreeUnavailable: false)
        }
        // A worktree was requested but git couldn't create it. Do NOT silently run in the main checkout
        // — fall back to the repo path but flag it so the caller refuses to auto-launch an agent there.
        guard let result = resolver(project.repoPath, project.worktreesDirectory, branch, project.defaultBranch) else {
            return WorkingDirectoryResolution(cwd: fallback, createdWorktree: false, worktreeUnavailable: true)
        }
        return WorkingDirectoryResolution(cwd: result.path, createdWorktree: result.created, worktreeUnavailable: false)
    }

    /// The directory a task's terminal *will* use, computed without touching git. For a Workspace
    /// branch it's the (possibly not-yet-created) worktree path — the worktree itself is created lazily
    /// the first time the task is opened (`ensureWorktreeCreated`), not at task creation. No branch →
    /// the project's main checkout.
    func plannedWorkingDirectory(
        forProject project: Project,
        repoPathOverride: String?,
        branchOrWorktree: String?
    ) -> String {
        let fallback = repoPathOverride?.nilIfBlank ?? project.repoPath
        guard let branch = (branchOrWorktree ?? "").nilIfBlank else {
            return fallback
        }
        return GitWorktreeManager.worktreePath(
            worktreesDirectory: project.resolvedWorktreesDirectory,
            branch: branch
        )
    }

    /// Creates the task's git worktree on first open, if it has a Workspace branch and the worktree
    /// doesn't exist yet. No-op when there's no branch, the worktree already exists (a later open), or
    /// there's no resolver (headless/tests). If git can't create it, resets the task's surfaces to the
    /// main checkout, clears the launch, and warns — mirroring the old create-time behavior, now
    /// deferred to when the task is actually opened.
    func ensureWorktreeCreated(taskID: TaskItem.ID) {
        guard worktreeResolver != nil,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              let branch = tasks[index].branchOrWorktree?.nilIfBlank,
              let project = project(for: tasks[index].projectID)
        else {
            return
        }
        let path = GitWorktreeManager.worktreePath(
            worktreesDirectory: project.resolvedWorktreesDirectory,
            branch: branch
        )
        // Already created on a prior open → nothing to do (cheap stat, no git).
        if FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
            return
        }

        let resolved = resolveWorkingDirectory(
            forProject: project,
            repoPathOverride: tasks[index].repoPathOverride,
            branchOrWorktree: branch
        )
        guard resolved.worktreeUnavailable else {
            return   // created successfully; the surfaces already point at `path`
        }
        for surfaceIndex in tasks[index].workspace.surfaces.indices
        where tasks[index].workspace.surfaces[surfaceIndex].cwd == path {
            tasks[index].workspace.surfaces[surfaceIndex].cwd = resolved.cwd
            tasks[index].workspace.surfaces[surfaceIndex].startupCommand = nil
            tasks[index].workspace.surfaces[surfaceIndex].setupCommand = nil
            tasks[index].workspace.surfaces[surfaceIndex].output =
                worktreeUnavailableBanner(branch: branch, cwd: resolved.cwd)
        }
    }

    /// After a task's workspace is edited (worktree ↔ main, a renamed branch, another project), moves
    /// the terminals that were headed for the old directory to the new one. Without this, a task made
    /// with a worktree and switched to "Work on main" before it was ever opened kept the never-created
    /// worktree path, so its terminal started in a missing directory (Ghostty falls back to $HOME) and
    /// ran the project's worktree setup there. Setup stays queued only for a worktree that is still
    /// to be created; the main checkout never gets it.
    func retargetWorkingDirectory(taskIndex index: Int, from previousDirectory: String) {
        guard let project = project(for: tasks[index].projectID) else { return }
        let directory = plannedWorkingDirectory(
            forProject: project,
            repoPathOverride: tasks[index].repoPathOverride,
            branchOrWorktree: tasks[index].branchOrWorktree
        )
        guard directory != previousDirectory else { return }
        let isPendingWorktree = tasks[index].branchOrWorktree?.nilIfBlank != nil
            && FileManager.default.fileExists(atPath: (directory as NSString).expandingTildeInPath) == false
        let setup = isPendingWorktree ? project.setupCommands?.nilIfBlank : nil
        for surfaceIndex in tasks[index].workspace.surfaces.indices
        where tasks[index].workspace.surfaces[surfaceIndex].cwd == previousDirectory {
            pointSurface(taskIndex: index, surfaceIndex: surfaceIndex, at: directory, setupCommand: setup)
        }
    }

    /// The safety net on open: a terminal whose directory doesn't exist would start in $HOME. Points
    /// it at the task's real directory instead (its worktree, else the main checkout) and drops setup
    /// unless that directory is the task's own worktree. Run after `ensureWorktreeCreated`.
    func repairMissingWorkingDirectories(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let project = project(for: tasks[index].projectID) else { return }
        let fileManager = FileManager.default
        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: (path as NSString).expandingTildeInPath) }
        let planned = plannedWorkingDirectory(
            forProject: project,
            repoPathOverride: tasks[index].repoPathOverride,
            branchOrWorktree: tasks[index].branchOrWorktree
        )
        let mainCheckout = tasks[index].repoPathOverride?.nilIfBlank ?? project.repoPath
        guard let target = [planned, mainCheckout].first(where: exists) else { return }
        let targetIsWorktree = target == planned && tasks[index].branchOrWorktree?.nilIfBlank != nil
        for surfaceIndex in tasks[index].workspace.surfaces.indices {
            let surface = tasks[index].workspace.surfaces[surfaceIndex]
            guard exists(surface.cwd) == false, surface.cwd != target else { continue }
            pointSurface(
                taskIndex: index,
                surfaceIndex: surfaceIndex,
                at: target,
                setupCommand: targetIsWorktree ? surface.setupCommand : nil
            )
        }
    }

    private func pointSurface(taskIndex index: Int, surfaceIndex: Int, at directory: String, setupCommand: String?) {
        let oldDirectory = tasks[index].workspace.surfaces[surfaceIndex].cwd
        tasks[index].workspace.surfaces[surfaceIndex].cwd = directory
        tasks[index].workspace.surfaces[surfaceIndex].setupCommand = setupCommand
        tasks[index].workspace.surfaces[surfaceIndex].environment["BALAGAN_WORKTREE_PATH"] = directory
        if let repoPath = project(for: tasks[index].projectID)?.repoPath {
            tasks[index].workspace.surfaces[surfaceIndex].environment["BALAGAN_REPO_PATH"] = repoPath
        }
        tasks[index].workspace.surfaces[surfaceIndex].agentLaunchMetadata?.cwd = directory
        // The untouched placeholder banner names the directory; keep it truthful.
        if tasks[index].workspace.surfaces[surfaceIndex].output == [Surface.pwdPlaceholderSeed, oldDirectory] {
            tasks[index].workspace.surfaces[surfaceIndex].output = [Surface.pwdPlaceholderSeed, directory]
        }
    }

    /// The task's git worktree (its "Workspace" branch) and whether that worktree directory still
    /// exists on disk — drives the card's worktree row (live vs. removed). `nil` when the task has no
    /// Workspace branch. `worktreePath` is pure path math (no git), and existence is a cheap stat.
    func worktreeInfo(for task: TaskItem) -> TaskWorktreeInfo? {
        guard let branch = task.branchOrWorktree?.nilIfBlank,
              let project = project(for: task.projectID)
        else {
            return nil
        }
        let path = GitWorktreeManager.worktreePath(
            worktreesDirectory: project.resolvedWorktreesDirectory,
            branch: branch
        )
        let exists = FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
        return TaskWorktreeInfo(branch: branch, path: path, exists: exists)
    }

    /// Points a task's terminals back at the project's main repo after its worktree was removed,
    /// so reopening them doesn't land in a now-deleted directory.
    func resetWorktreeWorkingDirectory(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let project = project(for: tasks[index].projectID) else {
            return
        }
        for surfaceIndex in tasks[index].workspace.surfaces.indices {
            tasks[index].workspace.surfaces[surfaceIndex].cwd = project.repoPath
            // The worktree is gone; never run its setup in the now-main-repo directory.
            tasks[index].workspace.surfaces[surfaceIndex].setupCommand = nil
        }
        tasks[index].updatedAt = Date()
    }

    /// Tears down a task's git worktree and its live terminal sessions, in the order and with the
    /// conditionality each call site needs. Shared by task-delete, worktree-remove, and archive — the
    /// three copies differed only in ordering (`closeSessionsFirst`), whether they repoint surfaces
    /// afterward (`resetWorkingDirectory`), and whether the worktree details are always present.
    /// Callers still run their own terminal step (`deleteTask` / `archiveTask`) afterward.
    ///
    /// The worktree block (`removeWorktree` → `deleteBranchIfMerged`) only runs when both `repoPath`
    /// and `worktreePath` are non-nil; branch deletion additionally requires a non-nil `branch`.
    ///
    /// - Parameters:
    ///   - force: force worktree removal even with uncommitted changes (dirty worktrees).
    ///   - closeSessionsFirst: when true, closes live terminals BEFORE removing the worktree (archive's
    ///     order); when false, removes the worktree first (delete / remove-worktree order).
    ///   - resetWorkingDirectory: when true, repoints the task's surfaces back to the main repo after
    ///     removal so reopening them doesn't land in a deleted directory. Skipped for task deletion,
    ///     where the task record is going away entirely.
    func removeWorktreeAndClose(
        taskID: TaskItem.ID,
        repoPath: String?,
        worktreePath: String?,
        branch: String?,
        force: Bool,
        closeSessionsFirst: Bool,
        resetWorkingDirectory: Bool
    ) {
        if closeSessionsFirst {
            TerminalHostRegistry.shared.closeTask(taskID: taskID)
        }
        if let repoPath, let worktreePath {
            GitWorktreeManager.removeWorktree(repoPath: repoPath, worktreePath: worktreePath, force: force)
            if let branch {
                GitWorktreeManager.deleteBranchIfMerged(repoPath: repoPath, branch: branch)
            }
        }
        if !closeSessionsFirst {
            TerminalHostRegistry.shared.closeTask(taskID: taskID)
        }
        if resetWorkingDirectory, repoPath != nil, worktreePath != nil {
            resetWorktreeWorkingDirectory(taskID: taskID)
        }
    }

    /// Clears a surface's one-time setup command once it has run (on first launch), so it never
    /// re-runs on a later relaunch.
    func consumeSetupCommand(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let surfaceIndex = tasks[taskIndex].workspace.surfaces.firstIndex(where: { $0.id == surfaceID }),
              tasks[taskIndex].workspace.surfaces[surfaceIndex].setupCommand != nil
        else {
            return
        }
        tasks[taskIndex].workspace.surfaces[surfaceIndex].setupCommand = nil
        tasks[taskIndex].updatedAt = Date()
    }
}
