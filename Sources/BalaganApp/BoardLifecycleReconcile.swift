import AppKit
import Darwin
import Foundation
import BalaganCore

extension BalaganApplication {
    /// Every 2s, correct any agent surface whose hook-driven lifecycle has drifted from reality
    /// (a missed event, needs-input that resumed, an unclean exit). Not started in `--ui-test-mode`
    /// (it stats files / probes pids). See `BoardViewModel.reconcileAgentLifecycles`.
    @MainActor
    func startLifecycleReconcile() {
        lifecycleReconcileTimer?.invalidate()
        lifecycleReconcileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel?.reconcileAgentLifecycles()
            }
        }
    }
}

/// Timer-driven safety net over agent working-state. For Claude the hooks (`UserPromptSubmit` /
/// `PreToolUse` → running, `Stop` → idle, `Notification` → needs-input) drive the transitions and this
/// clears a state stranded by a process that has since died, corroborating the rest against the
/// terminal-title spinner. For **Codex** — no hooks in our wrapper — this timer *is* the state machine:
/// the title alone decides. See `AgentLifecycleReconciler` (Core), which holds both tables.
extension BoardViewModel {
    /// Reconcile each agent surface's working-state: clear one stranded by a dead process, then either
    /// corroborate the hook state with the terminal-title spinner (Claude: recover a lost "running",
    /// clear a stuck spinner from a missed `Stop` or an Esc/interrupt) or derive the state from the
    /// title outright (Codex). The 2s cadence is also the debounce: a title read here is whatever the
    /// spinner settled on, never a single animation frame.
    ///
    /// Each tick first advances the per-surface spinner *streak*, which is what makes a hook-set
    /// `.needsInput` sticky: the spinner keeps animating for a moment after a permission dialog opens,
    /// so it takes two consecutive spinner-present ticks after the hook to read as `.running` again.
    func reconcileAgentLifecycles() {
        for taskIndex in tasks.indices {
            // A slept task is intentionally not running; its lifecycle was cleared at sleep.
            guard hibernatedTaskIDs.contains(tasks[taskIndex].id) == false else { continue }
            let taskID = tasks[taskIndex].id
            for surface in tasks[taskIndex].workspace.surfaces {
                let key = hostKey(taskID, surface.id)
                let streak = advanceTitleWorkingStreak(key)
                let signal = titleWorkingSignals[key]
                // Nothing to reconcile unless there's a hook state, a title signal or a running agent.
                guard surfaceLifecycle[key] != nil || signal != nil || runningAgents[key] != nil else { continue }
                // Unknown pid ⇒ can't prove death ⇒ treat as alive (never clear a working agent).
                let running = runningAgents[key]
                let processAlive = (surface.resumeBinding?.pid ?? running?.pid).map(Self.isProcessAlive) ?? true
                if processAlive == false, running != nil {
                    // The agent you typed at the prompt has quit; the tab is back to its shell.
                    runningAgents[key] = nil
                }
                let reconciled = AgentLifecycleReconciler.reconcile(
                    current: surfaceLifecycle[key],
                    processAlive: processAlive,
                    agentKind: surface.agentKind ?? AgentKind.named(running?.name),
                    titleSignal: signal?.signal,
                    titleFeatureActive: signal?.everWorked ?? false,
                    titleWorkingStreak: streak
                )
                setSurfaceLifecycle(reconciled, taskID: taskID, surfaceID: surface.id)
            }
        }
    }

    /// Records the latest title reading for a surface (from the `SET_TITLE` callback, already classified
    /// by `AgentTitleHeuristic`). Cheap and non-published; the 2s reconciler consumes it. Latches
    /// `everWorked` so later absence of a spinner is trusted only for surfaces proven to emit one (the
    /// Claude path; see `AgentLifecycleReconciler`).
    func updateTitleSignal(taskID: TaskItem.ID, surfaceID: Surface.ID, signal newSignal: AgentTitleHeuristic.TitleSignal) {
        let key = hostKey(taskID, surfaceID)
        var signal = titleWorkingSignals[key] ?? (signal: .idle, everWorked: false, workingStreak: 0)
        signal.signal = newSignal
        if newSignal == .working { signal.everWorked = true }
        titleWorkingSignals[key] = signal
    }

    /// Spinner-only convenience over `updateTitleSignal` (a title with no spinner and no
    /// "Action Required" is `.idle`).
    func updateTitleWorkingSignal(taskID: TaskItem.ID, surfaceID: Surface.ID, working: Bool) {
        updateTitleSignal(taskID: taskID, surfaceID: surfaceID, signal: working ? .working : .idle)
    }

    /// Counts this tick into the surface's spinner streak and returns it: +1 while the spinner is
    /// present, back to 0 the moment it's absent. Only surfaces with a title signal have a streak.
    private func advanceTitleWorkingStreak(_ key: TerminalHostKey) -> Int {
        guard var signal = titleWorkingSignals[key] else { return 0 }
        signal.workingStreak = signal.signal == .working ? signal.workingStreak + 1 : 0
        titleWorkingSignals[key] = signal
        return signal.workingStreak
    }

    /// Restarts the spinner streak for a surface. Called from `setSurfaceLifecycle` when a hook writes
    /// `.needsInput`, so the two ticks the reconciler needs to overturn it are counted from *after* the
    /// hook — the spinner still running from the pre-dialog moment must not count toward them.
    func resetTitleWorkingStreak(_ key: TerminalHostKey) {
        titleWorkingSignals[key]?.workingStreak = 0
    }

    /// `kill(pid, 0)` probes the process without signaling it: 0 = alive, `EPERM` = alive but ours-not,
    /// `ESRCH` = gone.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
