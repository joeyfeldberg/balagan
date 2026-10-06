import Foundation

/// A review note on one line of a task's diff, drafted in the Changes view and sent to the task's
/// agent in a batch.
public struct DiffComment: Hashable, Sendable, Codable, Identifiable {
    public enum Side: String, Hashable, Sendable, Codable {
        /// A line in the new version (added or unchanged): anchored by its new line number.
        case new
        /// A removed line: anchored by its old line number.
        case old
    }

    public var id: String
    public var path: String
    public var side: Side
    public var line: Int
    /// The line's text when the comment was made, quoted in the message so the agent sees exactly
    /// what it refers to even if the line has moved since.
    public var lineText: String
    public var body: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        path: String,
        side: Side,
        line: Int,
        lineText: String,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.side = side
        self.line = line
        self.lineText = lineText
        self.body = body
        self.createdAt = createdAt
    }

    /// Where a diff line can be commented on: its new number, or its old number for a removed line.
    public static func anchor(for line: DiffLine) -> (side: Side, line: Int)? {
        switch line.kind {
        case .removed: return line.oldNumber.map { (.old, $0) }
        case .added, .context: return line.newNumber.map { (.new, $0) }
        }
    }

    public func isAnchored(to line: DiffLine) -> Bool {
        guard let anchor = Self.anchor(for: line) else { return false }
        return anchor.side == side && anchor.line == self.line
    }
}

/// Turns a batch of diff comments into one message for the agent: grouped by file in file order,
/// then by line, each quoting the line it's about.
public enum ReviewMessage {
    public static func compose(_ comments: [DiffComment], fileOrder: [String] = []) -> String {
        let bodies = comments.filter { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard bodies.isEmpty == false else { return "" }
        func fileRank(_ path: String) -> Int { fileOrder.firstIndex(of: path) ?? Int.max }
        let sorted = bodies.sorted {
            (fileRank($0.path), $0.path, $0.line, $0.createdAt) < (fileRank($1.path), $1.path, $1.line, $1.createdAt)
        }
        let count = sorted.count
        var lines = ["I reviewed your changes and left \(count == 1 ? "a comment" : "\(count) comments"). Please address \(count == 1 ? "it" : "each one"):"]
        for comment in sorted {
            let where_ = comment.side == .old ? "\(comment.path), removed line \(comment.line)" : "\(comment.path):\(comment.line)"
            lines.append("")
            lines.append(where_)
            let quoted = comment.lineText.trimmingCharacters(in: .whitespaces)
            if quoted.isEmpty == false {
                lines.append("> \(quoted)")
            }
            lines.append(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.joined(separator: "\n")
    }
}
