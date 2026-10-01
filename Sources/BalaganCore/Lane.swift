import Foundation

/// A user-editable kanban column on a board. Lanes live on `Project` (per board), ordered by position.
/// A task's `status.rawValue` matches the `Lane.id` it sits in.
public struct Lane: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// RGB hex without a leading `#`, e.g. `4C8DFF`. Drives the column accent.
    public var colorHex: String
    /// Collapsed lanes render as a thin, click-to-expand strip on the board (a soft hide).
    public var collapsed: Bool

    public init(id: String, name: String, colorHex: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.collapsed = collapsed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, collapsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        // Migration: lanes saved before the collapse feature decode as expanded.
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    /// The lane a task in this column would carry.
    public var status: TaskStatus { TaskStatus(rawValue: id) }

    /// The built-in default lanes for a new board — the four historical statuses, same ids, names and
    /// colors, so existing tasks map straight across on migration.
    public static let defaults: [Lane] = [
        Lane(id: "todo", name: "Todo", colorHex: "8A93A6"),
        Lane(id: "doing", name: "Doing", colorHex: "4C8DFF"),
        Lane(id: "done", name: "Done", colorHex: "3FB970"),
        Lane(id: "parked", name: "Parked", colorHex: "C98A2B"),
    ]

    /// Colors handed to newly added lanes, by position, so a fresh lane reads distinctly without a color
    /// picker. Wraps around if a board has more lanes than entries.
    public static let palette: [String] = [
        "8A93A6", "4C8DFF", "3FB970", "C98A2B",
        "B980FF", "FF6B6B", "3FC7C7", "E0A23C", "7E8CA0",
    ]

    /// A url/id-safe slug for a lane name (lowercased, non-alphanumerics → single dashes).
    public static func slug(for name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if lastWasDash == false {
                slug.append("-")
                lastWasDash = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
