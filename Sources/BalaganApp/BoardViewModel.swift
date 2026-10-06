import AppKit
import Combine
import Foundation
import BalaganCore

final class BoardViewModel: ObservableObject, @unchecked Sendable {
    @Published var projects: [Project]
    @Published var tasks: [TaskItem]
    /// Sidebar visibility lives on the view model so the AppKit titlebar toggle and the SwiftUI body
    /// share one source of truth.
    @Published var isSidebarVisible = true
    @Published var selectedProjectID: Project.ID?
    @Published var selectedTaskID: TaskItem.ID?
    @Published var selectedWorkspaceID: String?
    @Published var selectedSurfaceID: Surface.ID?
    /// The pane zoomed to fill the workspace, if any (⌘⇧⏎). On the view model so a menu shortcut can
    /// toggle it; `TerminalWorkspace` binds to it. Cleared when the task changes.
    @Published var zoomedSurfaceID: Surface.ID?
    /// Bumped by the New Task shortcut so `BoardScreen` opens the create-task form from anywhere.
    @Published var pendingNewTaskRequest = false
    /// When true, the main area shows the Archived view instead of the board.
    @Published var showingArchived = false
    /// Drives the ⌘⇧P command palette overlay.
    @Published var showingCommandPalette = false
    /// When true, the selected task's terminal pane is swapped for the reader view (a typographic
    /// rendering of the active surface's agent transcript). Runtime-only (not persisted).
    @Published var showingReaderMode = false
    /// When true, the selected task's terminal pane is swapped for the Changes view (its branch's diff).
    /// Runtime-only; mutually exclusive with reader mode.
    @Published var showingChangesView = false
    /// Each task's last-loaded changes (see `BoardTaskChanges`). Runtime-only.
    @Published var taskChanges: [TaskItem.ID: TaskChangesState] = [:]
    /// Tasks with a git read in flight (drives the refresh spinner, and dedupes overlapping loads).
    @Published var taskChangesRefreshing: Set<TaskItem.ID> = []
    /// Run git reads inline instead of on a queue — `--ui-test-mode`, so snapshots are deterministic.
    var synchronousGitReads = false
    /// Surfaces where an agent finished/notified while the user wasn't looking. Runtime-only (not
    /// persisted). Bubbles up: a task needs attention if any of its surfaces do; a project if any of
    /// its tasks do. Cleared when the user opens/focuses the surface.
    ///
    /// Keyed by the composite `TerminalHostKey(taskID, surfaceID)`, NOT the bare `Surface.ID`: surface
    /// ids are only unique within a workspace (extra tabs slug their id from the title), so a global
    /// `Surface.ID` map would let two tasks with a same-slug tab share one slot and bleed status into
    /// each other. The composite matches how `TerminalHostRegistry` already keys its hosts.
    @Published var surfacesNeedingAttention: Set<TerminalHostKey> = []
    /// Agent working-state per surface (running / idle / needs-input), from the agent's hooks. Runtime
    /// only. Drives the "working" spinner on task cards. Composite-keyed (see `surfacesNeedingAttention`).
    @Published var surfaceLifecycle: [TerminalHostKey: AgentLifecycle] = [:]
    /// When each surface's `surfaceLifecycle` last changed — the "Waiting 4m" on a card. Written in the
    /// same call that writes the lifecycle, so it publishes no more often. Runtime-only, composite-keyed.
    @Published var surfaceLifecycleSince: [TerminalHostKey: Date] = [:]
    /// A plain-text preview of each agent surface's latest response, read from its transcript tail
    /// when the agent stops (idle / needs-input) and once at launch. Runtime-only, composite-keyed.
    @Published var surfaceLastResponses: [TerminalHostKey: String] = [:]
    /// The newest in-flight transcript read per surface, so an older read finishing late can't
    /// overwrite a newer one. Not published.
    var lastResponseReadTokens: [TerminalHostKey: UUID] = [:]
    /// Gates transcript reads for the board's activity previews. Off in `--ui-test-mode` so snapshots
    /// never pick up the user's real transcripts through the session-id fallback.
    var transcriptPreviewsEnabled = true
    /// Per-surface terminal-title reading (`AgentTitleHeuristic.classify`: working / blocked / idle),
    /// used by the 2s reconciler to corroborate `surfaceLifecycle` for Claude — recovering a lost
    /// "running" or clearing a stuck spinner from a missed hook — and to *derive* it outright for Codex,
    /// which has no hooks. Runtime-only and deliberately *not* `@Published` (it must not churn autosave;
    /// the spinner animates several times a second). `everWorked` latches true once a spinner is seen, so
    /// later absence of one is trusted only for surfaces that actually emit it. `workingStreak` counts
    /// consecutive reconcile ticks with the spinner present (reset when it's absent, and when a hook
    /// sets `.needsInput`) — it takes two to overturn a waiting agent. Composite-keyed.
    var titleWorkingSignals: [TerminalHostKey: (
        signal: AgentTitleHeuristic.TitleSignal,
        everWorked: Bool,
        workingStreak: Int
    )] = [:]
    /// Tasks the user has put to sleep: their terminal hosts are freed (memory reclaimed, child
    /// processes terminated) and rebuilt via the normal resume/replay path when the task is next
    /// opened. Runtime-only (not persisted) — after a restart a slept task is just a not-yet-reopened
    /// task, which the existing launch flow already handles. Drives the "asleep" badge on task cards.
    @Published var hibernatedTaskIDs: Set<TaskItem.ID> = []
    /// Tasks with at least one live terminal right now (reported by `TerminalHostRegistry`). Everything
    /// else is dormant — see `BoardDormancy`. Runtime-only.
    @Published var liveTaskIDs: Set<TaskItem.ID> = []
    /// Off in `--ui-test-mode`, whose fake terminals never register a host (every task would read as
    /// dormant); then only an explicit sleep shows the moon.
    var tracksLiveTerminals = true
    /// Starts a task's terminals off-screen. Installed by the app (it owns the terminal runtime).
    var backgroundTaskWaker: ((TaskItem.ID) -> Void)?
    /// Agents running in a tab whose session Balagan doesn't know yet (OpenCode before your first
    /// message, Codex in its first seconds, or any agent you typed at a prompt): the wrapper reported
    /// the start without an id. Makes the tab an agent tab right away; cleared when the process dies or
    /// the session arrives. Runtime-only.
    @Published var runningAgents: [TerminalHostKey: RunningAgent] = [:]
    /// Installed agents by profile id → executable path, from your login shell's PATH. nil until
    /// detection has run (then every profile is offered). See `BoardAgentInstallation`.
    @Published var installedAgents: [String: String]?
    /// Agent tabs whose process exited and that are waiting on the user (Resume / Close). Runtime-only.
    @Published var endedAgents: [TerminalHostKey: EndedAgent] = [:]
    /// A short-lived "resumed after it exited" note for one tab (see `BoardAgentExit`).
    @Published var agentAutoResumeNotice: (key: TerminalHostKey, text: String)?
    /// When each tab's process last started (quick-exit detection) and its recent automatic resumes
    /// (loop guard). Runtime-only, not published.
    var surfaceLaunchedAt: [TerminalHostKey: Date] = [:]
    var autoResumeHistory: [TerminalHostKey: [Date]] = [:]
    /// Relaunches an agent tab in place, resuming its session. Installed by the app (it owns the
    /// terminal runtime); nil headless.
    var agentRelauncher: ((TaskItem.ID, Surface.ID) -> Void)?
    /// Why a task went to sleep on its own ("Slept after 30m idle"), for the card's moon tooltip.
    /// Cleared on wake; absent for a manual sleep. Runtime-only.
    @Published var autoSleepReasons: [TaskItem.ID: String] = [:]
    /// When the user last opened or left each task — auto-sleep's idle clock (with agent state
    /// changes). Runtime-only, not published.
    var taskLastActiveAt: [TaskItem.ID: Date] = [:]
    /// The pull request (state, CI checks, comments, reviews) for each task that has one, fetched from
    /// GitHub via `gh`. Runtime-only (not persisted) — refetched on a poll + on demand. Absent = no PR
    /// / not fetched yet. Drives the CI badge on cards and the PR panel in the task header.
    @Published var pullRequests: [TaskItem.ID: TaskPullRequest] = [:]
    /// Tasks with a `gh` fetch in flight (drives the refresh spinner, and dedupes overlapping polls).
    @Published var pullRequestsRefreshing: Set<TaskItem.ID> = []
    /// Set when `gh` can't be found/authed, so the UI can hint at it instead of silently showing nothing.
    @Published var pullRequestsUnavailableReason: String?
    /// Gates all `gh` fetching. Disabled in `--ui-test-mode` so snapshots/UI tests stay deterministic
    /// and never spawn a real `gh` subprocess (seeded PR data still displays).
    var pullRequestTrackingEnabled = true
    /// Subscription usage per agent (sidebar meter, `balagan usage`). See `BoardAgentUsage`.
    @Published var agentUsage: [AgentUsage] = []
    /// Off in `--ui-test-mode`: reading it means reading real agent files.
    var usageTrackingEnabled = true
    /// Local servers each task's terminals started (`BoardDevServers`).
    @Published var devServerPorts: [TaskItem.ID: [DevServerPort]] = [:]
    /// Off in `--ui-test-mode`: it scans the real process table.
    var devServerTrackingEnabled = true
    /// Gates the app-posted agent banners ("waiting for your input" / "finished"). Disabled in
    /// `--ui-test-mode` so a snapshot run never buzzes the user's Notification Centre, and off by
    /// default inside any XCTest process — unit tests drive real running→idle transitions on fixture
    /// view models, and the default poster would otherwise fire an osascript banner ("Build kanban
    /// shell — The agent finished") on every `swift test`. Tests that assert on banners opt back in.
    var agentNotificationsEnabled = !BoardViewModel.isRunningUnderXCTest

    static let isRunningUnderXCTest: Bool =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// Whether Balagan is the frontmost app — a banner is suppressed only when the user is looking
    /// at the surface *and* in the app. Injected so headless tests can drive it (and so nothing here
    /// touches `NSApp`, which would spin up an application instance in a test bundle).
    var appIsFrontmost: () -> Bool = { NSRunningApplication.current.isActive }
    /// Posts an agent banner. Injected so tests can capture instead of notifying.
    var postAgentBanner: (AgentBanner) -> Void = { banner in
        SystemNotificationPresenter.shared.post(
            title: banner.title,
            body: banner.body,
            taskID: banner.taskID,
            surfaceID: banner.surfaceID
        )
    }
    /// How long a "waiting for your input" banner is held before firing, so a prompt the user answers
    /// straight away never buzzes. Re-validated when it fires (see `AgentAttentionPolicy`).
    var waitingBannerDelay: TimeInterval = 5
    /// At most one pending waiting banner per surface (debounce); cancelled when the state leaves
    /// `needsInput`. Runtime-only and not `@Published` — it drives no view.
    var pendingWaitingBanners: [TerminalHostKey: DispatchWorkItem] = [:]
    /// Surfaces whose current waiting episode has already produced a banner, so losing focus again
    /// doesn't re-nag. Cleared when the state leaves `needsInput`. Runtime-only.
    var postedWaitingBanners: Set<TerminalHostKey> = []
    @Published var terminalAppearance: TerminalAppearanceSettings
    @Published var uiAppearance: UIAppearanceSettings
    @Published var keyboardShortcuts: KeyboardShortcutSettings
    let agentWrapperPath: String?
    let dataSource: String
    var recoveredCodexSurfaceCount: Int = 0
    /// Resolves (and, in the live app, creates) a git worktree for a task's "Workspace" branch.
    /// Injected by the app for the live terminal path only; nil in tests/headless so no git runs.
    /// Args: (repoPath, worktreesDirectory, branch, baseBranch) → worktree result, or nil to fall back.
    var worktreeResolver: ((String, String?, String, String?) -> GitWorktreeManager.WorktreeResult?)?

    init(
        projects: [Project],
        tasks: [TaskItem],
        selectedProjectID: Project.ID? = nil,
        selectedTaskID: TaskItem.ID?,
        selectedWorkspaceID: String? = nil,
        selectedSurfaceID: Surface.ID? = nil,
        terminalAppearance: TerminalAppearanceSettings = TerminalAppearanceSettings(),
        uiAppearance: UIAppearanceSettings = UIAppearanceSettings(),
        keyboardShortcuts: KeyboardShortcutSettings = KeyboardShortcutSettings(),
        agentWrapperPath: String? = nil,
        dataSource: String = "unknown"
    ) {
        self.projects = projects
        self.tasks = tasks
        self.selectedProjectID = selectedProjectID
        self.selectedTaskID = selectedTaskID
        self.selectedWorkspaceID = selectedWorkspaceID ?? selectedTaskID.flatMap { taskID in
            tasks.first { $0.id == taskID }?.workspace.id
        }
        self.selectedSurfaceID = selectedSurfaceID ?? selectedTaskID.flatMap { taskID in
            tasks.first { $0.id == taskID }?.workspace.selectedSurfaceID
        }
        self.terminalAppearance = terminalAppearance
        self.uiAppearance = uiAppearance
        self.keyboardShortcuts = keyboardShortcuts
        self.agentWrapperPath = agentWrapperPath
        self.dataSource = dataSource
        if let selectedTaskID,
           let selectedSurfaceID = self.selectedSurfaceID,
           let index = self.tasks.firstIndex(where: { $0.id == selectedTaskID }),
           self.tasks[index].workspace.surfaces.contains(where: { $0.id == selectedSurfaceID }) {
            self.tasks[index].workspace.selectedSurfaceID = selectedSurfaceID
        }
        recoverPendingCodexSurfaces()
    }

    var selectedTask: TaskItem? {
        guard let selectedTaskID else {
            return nil
        }

        return tasks.first { $0.id == selectedTaskID }
    }

    var selectedResumePlan: ResumeCommandPlan? {
        guard let selectedTask else {
            return nil
        }

        guard let selectedSurfaceID = selectedSurfaceID
            ?? selectedTask.workspace.selectedSurfaceID
            ?? selectedTask.workspace.surfaces.first?.id else {
            return nil
        }
        return selectedTask.workspace.surfaces.first { $0.id == selectedSurfaceID }?.resumePlan(taskID: selectedTask.id)
    }

    /// Real, board-visible tasks (excludes the per-project hidden "Terminals" workspaces and archived
    /// tasks).
    var boardTasks: [TaskItem] {
        tasks.filter { $0.isProjectTerminals == false && $0.isArchived == false }
    }

    /// Archived tasks (most-recently-archived first), shown in the Archived view.
    var archivedTasks: [TaskItem] {
        tasks
            .filter { $0.isArchived && $0.isProjectTerminals == false }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    var filteredTasks: [TaskItem] {
        guard let selectedProjectID else {
            return boardTasks
        }

        return boardTasks.filter { $0.projectID == selectedProjectID }
    }

    func tasks(for status: TaskStatus) -> [TaskItem] {
        filteredTasks.filter { $0.status == status }
    }

    /// The kanban columns for the board currently on screen — the selected project's lanes (per board),
    /// falling back to the defaults when no project is selected.
    var boardLanes: [Lane] {
        if let selectedProjectID, let project = project(for: selectedProjectID) {
            return project.lanes
        }
        return Lane.defaults
    }
}

/// An agent the wrapper reported as started in a tab, before Balagan knows its session.
struct RunningAgent: Equatable {
    var name: String
    var pid: Int32?
}
