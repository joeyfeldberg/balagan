import Foundation

/// A task's lane, identified by a string id that matches a `Lane.id` on the task's project. Lanes are
/// user-editable per board, so this is an open string value (not a fixed enum) — but the four historical
/// lanes are exposed as static members so existing call sites keep compiling, and they remain the
/// default lane set for a new board.
public struct TaskStatus: RawRepresentable, Codable, Equatable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    // The built-in default lanes' ids (also the historical enum cases).
    public static let todo = TaskStatus(rawValue: "todo")
    public static let doing = TaskStatus(rawValue: "doing")
    public static let done = TaskStatus(rawValue: "done")
    public static let parked = TaskStatus(rawValue: "parked")

    /// The default lanes for a new board, in order.
    public static let defaults: [TaskStatus] = [.todo, .doing, .done, .parked]

    /// Human label. The authoritative display name is the `Lane.name` (editable); this is a fallback for
    /// contexts that only have the id — the built-ins get their historical capitalization, a custom id is
    /// title-cased from its slug.
    public var displayName: String {
        switch rawValue {
        case "todo": return "Todo"
        case "doing": return "Doing"
        case "done": return "Done"
        case "parked": return "Parked"
        default:
            return rawValue
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Migration: an empty/blank stored status falls back to the first default lane. Real ids
        // (including custom lane ids) pass through unchanged, so a task keeps its column.
        let stored = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = stored.isEmpty ? TaskStatus.todo.rawValue : stored
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
