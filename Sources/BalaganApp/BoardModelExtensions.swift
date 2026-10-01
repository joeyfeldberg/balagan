import Foundation
import BalaganCore

// App-only helpers on the core domain enums, kept here (not in Core) because they are UI-test /
// fixture concerns rather than domain rules. These replace the former duplicate app-side enums
// (BoardStatus / app TaskPriority), which collapsed into BalaganCore.TaskStatus / .TaskPriority.

extension TaskStatus {
    /// Stable, lowercase identifier fragment for accessibility IDs (e.g. "column-todo").
    var accessibilitySlug: String { rawValue }
}

extension TaskPriority {
    /// Maps a fixture's integer priority (1 = highest) onto the domain enum.
    static func fixtureValue(_ value: Int) -> TaskPriority {
        switch value {
        case ...1:
            return .high
        case 2:
            return .medium
        default:
            return .low
        }
    }
}
