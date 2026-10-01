import Foundation

/// The "recent tasks" the command palette puts first when you haven't typed anything.
public enum RecentTasks {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        /// When you last opened or left it (nil = never, this session or before).
        public var lastActiveAt: Date?

        public init(id: String, lastActiveAt: Date?) {
            self.id = id
            self.lastActiveAt = lastActiveAt
        }
    }

    /// Most recent first, skipping the task you're already in and anything never opened.
    public static func ids(_ candidates: [Candidate], excluding current: String?, limit: Int = 5) -> [String] {
        candidates
            .filter { $0.id != current && $0.lastActiveAt != nil }
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
            .prefix(limit)
            .map(\.id)
    }
}
