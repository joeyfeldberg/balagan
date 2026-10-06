import Foundation
import BalaganCore

// `AgentLifecycle` now lives in BalaganCore (so the pure `AgentLifecycleReconciler` can be tested).

/// A flagged surface (agent finished/notified) surfaced in the titlebar bell menu.
struct AttentionTarget: Identifiable {
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID
    let title: String
    let detail: String
    /// Composite: surface ids are only workspace-unique, so identifying by surface alone collides
    /// across tasks (duplicate `Identifiable` ids in a menu `ForEach`).
    var id: String { "\(taskID)::\(surfaceID)" }
}

/// An agent terminal listed in the titlebar "agent sessions" menu.
struct AgentSessionItem: Identifiable {
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID
    let taskTitle: String
    let surfaceTitle: String
    let lifecycle: AgentLifecycle?
    var id: String { "\(taskID)::\(surfaceID)" }
}

/// Agent-attention highlights and the titlebar session/notification menus.
///
/// All per-surface status (`surfaceLifecycle`, `surfacesNeedingAttention`, `titleWorkingSignals`) is
/// keyed by the composite `TerminalHostKey(taskID, surfaceID)` — surface ids are only unique within a
/// workspace, so keying globally by `Surface.ID` let two tasks with a same-slug tab share one slot and
/// bleed status into each other. Every read/write goes through `hostKey`, matching how
/// `TerminalHostRegistry` already keys its live hosts.
extension BoardViewModel {
    // MARK: - Composite key

    func hostKey(_ taskID: TaskItem.ID, _ surfaceID: Surface.ID) -> TerminalHostKey {
        TerminalHostKey(taskID: taskID, surfaceID: surfaceID)
    }

    // MARK: - Agent-attention highlights (tab → task → project)

    /// Flags a surface as needing attention (an agent finished/notified while it wasn't focused).
    func flagSurfaceNeedsAttention(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        // A hibernated task's agents are terminated and its hosts freed; never let a late edge (e.g. a
        // dying agent's bell as it's SIGTERM'd on sleep) flag a slept task for attention.
        guard hibernatedTaskIDs.contains(taskID) == false else { return }
        surfacesNeedingAttention.insert(hostKey(taskID, surfaceID))
    }

    func clearSurfaceAttention(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        surfacesNeedingAttention.remove(hostKey(taskID, surfaceID))
    }

    /// Whether a surface is running an agent — it captured an agent session (`resumeBinding.kind ==
    /// .agent`) or has reported an agent working-state. Balagan notifications/attention are for
    /// agents only, so a plain shell running a service (which can still emit an OSC-9 desktop
    /// notification or a bell) doesn't raise a banner or an attention highlight.
    func surfaceIsAgentTerminal(taskID: TaskItem.ID, surfaceID: Surface.ID) -> Bool {
        if surfaceLifecycle[hostKey(taskID, surfaceID)] != nil { return true }
        if runningAgents[hostKey(taskID, surfaceID)] != nil { return true }
        guard let task = tasks.first(where: { $0.id == taskID }),
              let surface = task.workspace.surfaces.first(where: { $0.id == surfaceID })
        else {
            return false
        }
        return surface.resumeBinding?.kind == .agent
    }

    func surfaceNeedsAttention(taskID: TaskItem.ID, surfaceID: Surface.ID) -> Bool {
        surfacesNeedingAttention.contains(hostKey(taskID, surfaceID))
    }

    /// True if any of the task's surfaces need attention. A slept task never surfaces attention (its
    /// agents are terminated and its surfaces torn down) — invariant enforced here, mirroring
    /// `taskIsRunning`, so a stale flag can't badge a sleeping card.
    func taskNeedsAttention(_ task: TaskItem) -> Bool {
        guard surfacesNeedingAttention.isEmpty == false, hibernatedTaskIDs.contains(task.id) == false else {
            return false
        }
        return task.workspace.surfaces.contains { surfacesNeedingAttention.contains(hostKey(task.id, $0.id)) }
    }

    /// True if any task in the project (including its hidden Terminals workspace) needs attention.
    func projectNeedsAttention(_ projectID: Project.ID) -> Bool {
        guard surfacesNeedingAttention.isEmpty == false else { return false }
        return tasks.contains { $0.projectID == projectID && taskNeedsAttention($0) }
    }

    /// True if any of the task's surfaces has an agent actively working (between prompt-submit and stop).
    /// A slept task is never "running" (its processes are terminated) — invariant enforced here too.
    func taskIsRunning(_ task: TaskItem) -> Bool {
        guard surfaceLifecycle.isEmpty == false, hibernatedTaskIDs.contains(task.id) == false else {
            return false
        }
        return task.workspace.surfaces.contains { surfaceLifecycle[hostKey(task.id, $0.id)] == .running }
    }

    /// True if this surface's agent is blocked on the user (a permission/approval prompt). The unit
    /// the terminal tab strip renders, so the waiting glyph points at the exact tab that's asking.
    func surfaceIsWaiting(taskID: TaskItem.ID, surfaceID: Surface.ID) -> Bool {
        guard hibernatedTaskIDs.contains(taskID) == false else { return false }
        return surfaceLifecycle[hostKey(taskID, surfaceID)] == .needsInput
    }

    /// True if the task is waiting on the user and nothing in it is working (the card/sidebar glyph).
    func taskIsWaiting(_ task: TaskItem) -> Bool {
        taskAgentState(task) == .needsInput
    }

    /// The project's aggregate agent state across its (unarchived) tasks, using the same
    /// running > needs-input > idle precedence a task uses across its surfaces — so a sidebar project
    /// row shows exactly what the loudest card under it shows.
    func projectAgentState(_ projectID: Project.ID) -> TaskAgentState {
        guard surfaceLifecycle.isEmpty == false else { return .none }
        var sawNeedsInput = false
        var sawIdle = false
        for task in tasks where task.projectID == projectID && task.isArchived == false {
            switch taskAgentState(task) {
            case .running: return .running
            case .needsInput: sawNeedsInput = true
            case .idle: sawIdle = true
            case .asleep, .none: continue
            }
        }
        if sawNeedsInput { return .needsInput }
        return sawIdle ? .idle : .none
    }

    /// The task's aggregate agent state (running / needs-input / idle / asleep / none) — powers the
    /// control-socket `state` and `wait` commands an orchestrator uses to track a sub-agent.
    func taskAgentState(_ task: TaskItem) -> TaskAgentState {
        let lifecycles = task.workspace.surfaces.map { surfaceLifecycle[hostKey(task.id, $0.id)] }
        let hasAgentSurface = task.workspace.surfaces.contains { surface in
            surfaceLifecycle[hostKey(task.id, surface.id)] != nil || surface.resumeBinding?.kind == .agent
        }
        return TaskAgentState.aggregate(
            lifecycles: lifecycles,
            hasAgentSurface: hasAgentSurface,
            hibernated: hibernatedTaskIDs.contains(task.id)
        )
    }

    /// Records an agent working-state update for a surface (from its hooks).
    func setSurfaceLifecycle(_ raw: String?, taskID: TaskItem.ID, surfaceID: Surface.ID) {
        setSurfaceLifecycle(raw.flatMap(AgentLifecycle.init(rawValue:)), taskID: taskID, surfaceID: surfaceID)
    }

    /// Records an agent working-state update for a surface (typed; used by the reconciler).
    func setSurfaceLifecycle(_ lifecycle: AgentLifecycle?, taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = hostKey(taskID, surfaceID)
        let previous = surfaceLifecycle[key]
        guard previous != lifecycle else { return }
        surfaceLifecycle[key] = lifecycle
        surfaceLifecycleSince[key] = lifecycle == nil ? nil : Date()

        // The agent just stopped — to answer, or to ask. That's when the last response changes, and
        // when its subscription usage has moved.
        if lifecycle == .idle || lifecycle == .needsInput {
            refreshAgentUsage()
            refreshTaskTokens(taskIDs: [taskID])
            refreshLastResponse(taskID: taskID, surfaceID: surfaceID)
            refreshVisibleChangesAfterAgentStopped(taskID: taskID)
        }

        // A fresh "waiting on the user" wins over the title spinner, which keeps animating for a moment
        // after the permission dialog opens: restart the streak so the reconciler needs two spinner ticks
        // from *now* before it reads this surface as working again (see `AgentLifecycleReconciler`).
        if lifecycle == .needsInput { resetTitleWorkingStreak(key) }

        // "Finished off-screen": when an agent completes a turn (running → idle) on a surface you're not
        // currently viewing, flag it so the board shows finished work you haven't seen — cleared when you
        // focus it. Unlike the bell/desktop-notification path this needs no escape from the agent, so a
        // quietly-ending turn still surfaces. (A waiting `needs-input` agent is surfaced separately, from
        // its live lifecycle, so it shows even while selected.)
        let isSelectedSurface = (taskID == selectedTaskID && surfaceID == selectedSurfaceID)
        if previous == .running, lifecycle == .idle, isSelectedSurface == false {
            flagSurfaceNeedsAttention(taskID: taskID, surfaceID: surfaceID)
        }

        // Waiting/finished highlights + the app-posted desktop banners (see `BoardAgentBanners`).
        applyAgentAttentionPolicy(previous: previous, next: lifecycle, taskID: taskID, surfaceID: surfaceID)
    }

    /// The surfaces currently flagged as needing attention, with their task/project labels — drives the
    /// titlebar notification bell's menu.
    func attentionTargets() -> [AttentionTarget] {
        guard surfacesNeedingAttention.isEmpty == false else { return [] }
        var targets: [AttentionTarget] = []
        for task in tasks where hibernatedTaskIDs.contains(task.id) == false {
            for surface in task.workspace.surfaces where surfacesNeedingAttention.contains(hostKey(task.id, surface.id)) {
                targets.append(AttentionTarget(
                    taskID: task.id,
                    surfaceID: surface.id,
                    title: task.isProjectTerminals ? "\(projectName(for: task.projectID)) — Terminals" : task.title,
                    detail: task.isProjectTerminals ? surface.title : projectName(for: task.projectID)
                ))
            }
        }
        return targets
    }

    /// Jumps to a flagged surface (selecting its task + surface, which clears its attention highlight).
    func jumpToAttention(_ target: AttentionTarget) {
        guard let task = tasks.first(where: { $0.id == target.taskID }) else { return }
        select(task: task)
        select(surfaceID: target.surfaceID, forTaskID: target.taskID)
    }

    /// Every agent terminal across the board (a captured agent session, or one that has reported a
    /// working state), in stable board order — drives the titlebar "agent sessions" menu.
    ///
    /// The order is deliberately *not* sorted by live lifecycle. Sorting running-first meant that while
    /// the menu was open, agents flipping between running and idle re-sorted the list and the rows
    /// jumped around under the cursor. Board order is stable, and each row's icon still reflects its
    /// current state (running / needs-input / idle), so nothing is lost.
    func agentSessions() -> [AgentSessionItem] {
        var items: [AgentSessionItem] = []
        for task in tasks where task.isArchived == false && hibernatedTaskIDs.contains(task.id) == false {
            for surface in task.workspace.surfaces {
                let key = hostKey(task.id, surface.id)
                let isAgent = surfaceLifecycle[key] != nil || surface.resumeBinding?.kind == .agent
                guard isAgent else { continue }
                items.append(AgentSessionItem(
                    taskID: task.id,
                    surfaceID: surface.id,
                    taskTitle: task.isProjectTerminals ? "\(projectName(for: task.projectID)) — Terminals" : task.title,
                    surfaceTitle: surface.title,
                    lifecycle: surfaceLifecycle[key]
                ))
            }
        }
        return items
    }

    /// The agents that want something from you right now — working (`running`) or blocked on you
    /// (`needsInput`). Drives the titlebar menu; the two badges are counted off this same list, so a
    /// badge can never disagree with the rows behind it (they used to: the count read raw dictionary
    /// values while the menu walked the task graph, double-counting any surface-id collision across
    /// workspaces).
    func activeAgentSessions() -> [AgentSessionItem] {
        agentSessions().filter { $0.lifecycle == .running || $0.lifecycle == .needsInput }
    }

    /// Number of agents actively working right now (the green badge on the sessions menu).
    var runningAgentCount: Int {
        activeAgentSessions().filter { $0.lifecycle == .running }.count
    }

    /// Number of agents blocked on the user right now (the amber badge on the sessions menu).
    var waitingAgentCount: Int {
        activeAgentSessions().filter { $0.lifecycle == .needsInput }.count
    }

    /// Seeds deterministic agent states for headless snapshots (`BALAGAN_FIXTURE_AGENT_STATES=1`):
    /// the first task waiting on the user, the second working, the third finished off-screen. One
    /// capture then shows all three glyphs at once — on the cards, on the sidebar project rows, and
    /// (for the selected task) on its terminal tab.
    /// One task's seeded activity, read from `BALAGAN_FIXTURE_AGENT_STATES_FILE` (a JSON object keyed by
    /// task id) so a snapshot can show varied, realistic cards instead of the three canned ones.
    struct SnapshotActivity: Decodable {
        var state: String
        var summary: String?
        var response: String?
        var minutes: Double?
    }

    func seedAgentStatesForSnapshot() {
        if let path = ProcessInfo.processInfo.environment["BALAGAN_FIXTURE_AGENT_STATES_FILE"],
           let data = FileManager.default.contents(atPath: path),
           let seeds = try? JSONDecoder().decode([String: SnapshotActivity].self, from: data) {
            seedAgentStates(seeds)
            return
        }
        let seedable = tasks.filter { $0.isArchived == false && $0.isProjectTerminals == false }
        for (index, task) in seedable.enumerated() {
            guard let surfaceID = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id else {
                continue
            }
            let key = hostKey(task.id, surfaceID)
            switch index % 3 {
            case 0:
                setSurfaceLifecycle(.needsInput, taskID: task.id, surfaceID: surfaceID)
                updateSurfaceMetadata(taskID: task.id, surfaceID: surfaceID, title: "✳ Wire the board fixtures", cwd: nil)
                surfaceLastResponses[key] = "The fixture loader is in place. Should I also migrate the old JSON fixtures, or leave them for now?"
                surfaceLifecycleSince[key] = Date().addingTimeInterval(-4 * 60)
            case 1:
                setSurfaceLifecycle(.running, taskID: task.id, surfaceID: surfaceID)
                updateSurfaceMetadata(taskID: task.id, surfaceID: surfaceID, title: "✳ Tighten deadline assertions", cwd: nil)
                surfaceLifecycleSince[key] = Date().addingTimeInterval(-12 * 60)
            default:
                // running → idle off-screen is what raises the "finished, go look" highlight.
                setSurfaceLifecycle(.running, taskID: task.id, surfaceID: surfaceID)
                setSurfaceLifecycle(.idle, taskID: task.id, surfaceID: surfaceID)
                updateSurfaceMetadata(taskID: task.id, surfaceID: surfaceID, title: "✳ Trace filter regression", cwd: nil)
                surfaceLastResponses[key] = "Found it: the service filter was dropped when the time range changed. Fixed and added a regression test; all 48 tests pass."
                surfaceLifecycleSince[key] = Date().addingTimeInterval(-65 * 60)
            }
        }
    }

    private func seedAgentStates(_ seeds: [String: SnapshotActivity]) {
        for task in tasks {
            guard let seed = seeds[task.id],
                  let surfaceID = task.workspace.selectedSurfaceID ?? task.workspace.surfaces.first?.id else {
                continue
            }
            let key = hostKey(task.id, surfaceID)
            if seed.state == "idle" {
                // running → idle off-screen raises the "finished, go look" highlight.
                setSurfaceLifecycle(.running, taskID: task.id, surfaceID: surfaceID)
            }
            setSurfaceLifecycle(seed.state, taskID: task.id, surfaceID: surfaceID)
            if let summary = seed.summary {
                updateSurfaceMetadata(taskID: task.id, surfaceID: surfaceID, title: "✳ \(summary)", cwd: nil)
            }
            surfaceLastResponses[key] = seed.response
            surfaceLifecycleSince[key] = Date().addingTimeInterval(-(seed.minutes ?? 1) * 60)
        }
    }

    /// Jumps to an agent session's task + surface.
    func jumpToSession(_ item: AgentSessionItem) {
        guard let task = tasks.first(where: { $0.id == item.taskID }) else { return }
        select(task: task)
        select(surfaceID: item.surfaceID, forTaskID: item.taskID)
    }
}
