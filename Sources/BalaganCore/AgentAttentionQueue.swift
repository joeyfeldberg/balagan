import Foundation

/// The order in which "jump to the next agent that needs you" visits agents.
///
/// Waiting agents come first, oldest first — the one that has been blocked on you longest is the
/// one you're costing the most. Then agents that finished while you weren't looking, also oldest
/// first. Pressing the shortcut again moves along the queue and wraps, so repeated presses walk
/// every agent that needs you.
public enum AgentAttentionQueue {
    public enum Reason: Int, Sendable, Comparable {
        case waiting = 0
        case finished = 1

        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Entry: Equatable, Sendable {
        public var taskID: String
        public var surfaceID: String
        public var reason: Reason
        /// When the agent entered this state; nil sorts last within its reason.
        public var since: Date?

        public init(taskID: String, surfaceID: String, reason: Reason, since: Date?) {
            self.taskID = taskID
            self.surfaceID = surfaceID
            self.reason = reason
            self.since = since
        }

        func isAt(taskID: String?, surfaceID: String?) -> Bool {
            self.taskID == taskID && self.surfaceID == surfaceID
        }
    }

    /// The queue, in visiting order. Input order breaks exact ties, so the result is stable.
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.enumerated().sorted { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            if l.reason != r.reason { return l.reason < r.reason }
            if l.since != r.since { return (l.since ?? .distantFuture) < (r.since ?? .distantFuture) }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Where to go next from the surface currently on screen. If that surface is in the queue, the
    /// entry after it (wrapping); otherwise the head of the queue. Nil when nothing needs you, or the
    /// only thing that does is what you're already looking at.
    public static func next(after currentTaskID: String?, surfaceID currentSurfaceID: String?, in entries: [Entry]) -> Entry? {
        let queue = ordered(entries)
        guard queue.isEmpty == false else { return nil }
        guard let index = queue.firstIndex(where: { $0.isAt(taskID: currentTaskID, surfaceID: currentSurfaceID) }) else {
            return queue[0]
        }
        guard queue.count > 1 else { return nil }
        return queue[(index + 1) % queue.count]
    }
}

/// Which tasks the sidebar lists under a project, and in what order.
public enum SidebarTaskList {
    /// The project's tasks in board order: lane by lane (the project's lane order), and within a lane
    /// the order they sit in on the board. Order is deliberately independent of agent state, so rows
    /// don't reshuffle under the cursor as agents start and stop.
    ///
    /// Done tasks are left out — the sidebar is for work in flight — unless one is selected or still
    /// has something to tell you (`keep`). Archived tasks and the hidden project Terminals workspace
    /// never appear.
    public static func tasks(
        for project: Project,
        in tasks: [TaskItem],
        keep: (TaskItem) -> Bool = { _ in false }
    ) -> [TaskItem] {
        let laneOrder = Dictionary(
            project.lanes.enumerated().map { ($0.element.status, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return tasks.enumerated()
            .filter { _, task in
                task.projectID == project.id
                    && task.isArchived == false
                    && task.isProjectTerminals == false
                    && (task.status != .done || keep(task))
            }
            .sorted { lhs, rhs in
                // A task in a lane the project no longer has sorts after every real lane.
                let l = laneOrder[lhs.element.status] ?? Int.max
                let r = laneOrder[rhs.element.status] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
