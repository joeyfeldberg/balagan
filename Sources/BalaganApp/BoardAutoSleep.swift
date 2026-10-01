import Foundation
import BalaganCore

/// Automatic sleep: every minute (and whenever macOS reports memory pressure), put quiet tasks to
/// sleep with the same mechanism as the manual "Sleep". Which tasks is decided by the pure
/// `AutoSleepPlanner` (Core); this file only gathers the facts and performs the sleep.
extension BoardViewModel {
    static let autoSleepDefaultsKey = "autoSleepIdleMinutes"

    /// Minutes of quiet before a task sleeps; 0 = never. App-level (UserDefaults), like the speech
    /// settings — it's about this Mac's memory, not the board.
    var autoSleepIdleMinutes: Int {
        get {
            UserDefaults.standard.object(forKey: Self.autoSleepDefaultsKey) as? Int ?? AutoSleepPlanner.defaultIdleMinutes
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.autoSleepDefaultsKey)
        }
    }

    /// The idle threshold in seconds, or nil when the timer is off. `BALAGAN_AUTOSLEEP_IDLE_SECONDS`
    /// overrides it, so a live smoke doesn't have to wait half an hour.
    var autoSleepIdleThreshold: TimeInterval? {
        if let raw = ProcessInfo.processInfo.environment["BALAGAN_AUTOSLEEP_IDLE_SECONDS"],
           let seconds = TimeInterval(raw) {
            return seconds
        }
        let minutes = autoSleepIdleMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// Stamps "the user was just here" on a task — when it's opened and when it's left.
    func noteTaskActivity(_ taskID: TaskItem.ID?, at date: Date = Date()) {
        guard let taskID else { return }
        taskLastActiveAt[taskID] = date
    }

    /// The facts the planner needs about one task.
    @MainActor
    func autoSleepInput(for task: TaskItem, now: Date) -> AutoSleepPlanner.TaskInput {
        let surfaces = task.workspace.surfaces.map { surface -> AutoSleepPlanner.SurfaceState in
            let key = hostKey(task.id, surface.id)
            if let binding = surface.resumeBinding, binding.kind == .agent, binding.sessionID?.nilIfBlank != nil {
                // A resumed agent reports nothing until you prompt it, so "no state" is idle too —
                // the session is there to resume either way.
                switch surfaceLifecycle[key] {
                case .running, .needsInput: return .agentActive
                case .idle, nil: return .agentIdle
                }
            }
            if surfaceLifecycle[key] == .running || surfaceLifecycle[key] == .needsInput {
                return .agentActive
            }
            return TerminalHostRegistry.shared.terminalIsBusy(taskID: task.id, surfaceID: surface.id)
                ? .shellBusy
                : .shellIdle
        }
        // First sighting counts as activity, so nothing sleeps the moment the feature turns on.
        let lastSeen = taskLastActiveAt[task.id] ?? {
            taskLastActiveAt[task.id] = now
            return now
        }()
        let lastLifecycleChange = task.workspace.surfaces
            .compactMap { surfaceLifecycleSince[hostKey(task.id, $0.id)] }
            .max()
        return AutoSleepPlanner.TaskInput(
            taskID: task.id,
            isOnScreen: selectedTaskID == task.id,
            isAsleep: hibernatedTaskIDs.contains(task.id),
            hasLiveTerminals: TerminalHostRegistry.shared.hasHosts(taskID: task.id),
            hasUnseenResult: taskNeedsAttention(task),
            lastActiveAt: max(lastSeen, lastLifecycleChange ?? .distantPast),
            surfaces: surfaces
        )
    }

    /// One pass: sleep whatever the planner picks. Returns the tasks it put to sleep.
    @MainActor
    @discardableResult
    func runAutoSleep(underMemoryPressure: Bool = false, now: Date = Date()) -> [TaskItem.ID] {
        let inputs = tasks
            .filter { $0.isArchived == false && TerminalHostRegistry.shared.hasHosts(taskID: $0.id) }
            .map { autoSleepInput(for: $0, now: now) }
        let chosen = AutoSleepPlanner.tasksToSleep(
            inputs,
            now: now,
            idleThreshold: autoSleepIdleThreshold,
            underMemoryPressure: underMemoryPressure
        )
        for taskID in chosen {
            guard let input = inputs.first(where: { $0.taskID == taskID }) else { continue }
            sleepTask(taskID: taskID)
            if hibernatedTaskIDs.contains(taskID) {
                autoSleepReasons[taskID] = AutoSleepPlanner.reason(
                    idleSince: input.lastActiveAt,
                    sleptAt: now,
                    underMemoryPressure: underMemoryPressure
                )
            }
        }
        return chosen
    }
}

extension BalaganApplication {
    /// Runs auto-sleep once a minute and on macOS memory-pressure warnings, and keeps each task's idle
    /// clock fresh as you move between tasks. Not started in `--ui-test-mode`.
    @MainActor
    func startAutoSleep(viewModel: BoardViewModel) {
        // Opening a task and leaving it both count as activity.
        taskActivityCancellable = viewModel.$selectedTaskID
            .scan((previous: TaskItem.ID?.none, current: TaskItem.ID?.none)) { ($0.current, $1) }
            .sink { [weak viewModel] change in
                let now = Date()
                viewModel?.noteTaskActivity(change.previous, at: now)
                viewModel?.noteTaskActivity(change.current, at: now)
            }

        autoSleepTimer?.invalidate()
        autoSleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak viewModel] _ in
            MainActor.assumeIsolated {
                _ = viewModel?.runAutoSleep()
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak viewModel] in
            MainActor.assumeIsolated {
                _ = viewModel?.runAutoSleep(underMemoryPressure: true)
            }
        }
        source.resume()
        memoryPressureSource = source
    }
}
