import Foundation

/// Decides which tasks to put to sleep on their own, to give back the memory their live terminals
/// hold. Sleeping is the same mechanism as the manual "Sleep" (free every terminal, resume on reopen),
/// so the only question is *when it's safe*. The answer is conservative:
///
/// - Every terminal in the task must come back cleanly. An agent tab must be idle — it has a session
///   to resume. A plain shell must be sitting at its prompt — a running dev server or build can't be
///   resumed, so a task with one never sleeps.
/// - Nothing may want the user: no agent working or waiting, nothing finished-but-unseen.
/// - It isn't on screen, and it has been quiet for the idle threshold. Under memory pressure the
///   threshold drops to `pressureIdle`, so the system gets memory back sooner.
public enum AutoSleepPlanner {
    /// What a terminal is doing, as far as sleeping it is concerned.
    public enum SurfaceState: Equatable, Sendable {
        /// An agent tab whose agent is idle (resumable).
        case agentIdle
        /// An agent tab whose agent is working or waiting on the user.
        case agentActive
        /// A plain shell at its prompt, or a terminal whose process is gone.
        case shellIdle
        /// A plain shell with something running in it.
        case shellBusy
    }

    public struct TaskInput: Equatable, Sendable {
        public var taskID: String
        public var isOnScreen: Bool
        public var isAsleep: Bool
        public var hasLiveTerminals: Bool
        /// A finished agent the user hasn't looked at yet.
        public var hasUnseenResult: Bool
        /// The last time anything happened: the user left it, or an agent changed state.
        public var lastActiveAt: Date
        public var surfaces: [SurfaceState]

        public init(
            taskID: String,
            isOnScreen: Bool,
            isAsleep: Bool,
            hasLiveTerminals: Bool,
            hasUnseenResult: Bool,
            lastActiveAt: Date,
            surfaces: [SurfaceState]
        ) {
            self.taskID = taskID
            self.isOnScreen = isOnScreen
            self.isAsleep = isAsleep
            self.hasLiveTerminals = hasLiveTerminals
            self.hasUnseenResult = hasUnseenResult
            self.lastActiveAt = lastActiveAt
            self.surfaces = surfaces
        }
    }

    /// How quiet a task must be before it sleeps while the system is short on memory.
    public static let pressureIdle: TimeInterval = 2 * 60

    /// The idle-time choices offered in Settings, in minutes. 0 is "never".
    public static let idleMinuteChoices = [0, 15, 30, 60, 120]
    public static let defaultIdleMinutes = 30

    /// The tasks to sleep now, longest-idle first.
    ///
    /// - Parameters:
    ///   - idleThreshold: seconds of quiet before a task sleeps; nil turns the timer off (memory
    ///     pressure still applies — running out of memory is worse than a resume).
    ///   - underMemoryPressure: the system has asked apps to give memory back.
    public static func tasksToSleep(
        _ tasks: [TaskInput],
        now: Date,
        idleThreshold: TimeInterval?,
        underMemoryPressure: Bool
    ) -> [String] {
        let thresholds = [idleThreshold, underMemoryPressure ? pressureIdle : nil].compactMap { $0 }
        guard let threshold = thresholds.min() else { return [] }
        return tasks
            .filter { isSafeToSleep($0) && now.timeIntervalSince($0.lastActiveAt) >= threshold }
            .sorted { $0.lastActiveAt < $1.lastActiveAt }
            .map(\.taskID)
    }

    /// Every rule except the idle clock.
    public static func isSafeToSleep(_ task: TaskInput) -> Bool {
        guard task.isOnScreen == false,
              task.isAsleep == false,
              task.hasLiveTerminals,
              task.hasUnseenResult == false
        else {
            return false
        }
        return task.surfaces.allSatisfy { $0 == .agentIdle || $0 == .shellIdle }
    }

    /// "Slept after 30m idle" — the wording for a task that went to sleep on its own.
    public static func reason(idleSince: Date, sleptAt: Date, underMemoryPressure: Bool) -> String {
        let idle = TaskActivity.elapsed(from: idleSince, to: sleptAt)
        return underMemoryPressure
            ? "Slept to free memory after \(idle) idle"
            : "Slept after \(idle) idle"
    }
}
