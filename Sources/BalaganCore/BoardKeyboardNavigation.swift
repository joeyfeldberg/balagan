import Foundation

/// Arrow-key movement between cards on the board. Columns are the board's visible lanes, left to
/// right, each listing its card ids top to bottom (collapsed lanes are left out by the caller).
public enum BoardKeyboardNavigation {
    public enum Direction: Sendable { case up, down, left, right }

    /// The card to highlight after pressing `direction`. With nothing highlighted, any arrow picks the
    /// first card. Up/down stay in the column (stopping at its ends); left/right jump to the nearest
    /// column with cards, keeping roughly the same row.
    public static func next(from current: String?, direction: Direction, columns: [[String]]) -> String? {
        let firstCard = columns.first(where: { $0.isEmpty == false })?.first
        guard let current,
              let column = columns.firstIndex(where: { $0.contains(current) }),
              let row = columns[column].firstIndex(of: current) else {
            return firstCard
        }
        switch direction {
        case .up:
            return columns[column][max(row - 1, 0)]
        case .down:
            return columns[column][min(row + 1, columns[column].count - 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var target = column + step
            while columns.indices.contains(target), columns[target].isEmpty { target += step }
            guard columns.indices.contains(target) else { return current }
            return columns[target][min(row, columns[target].count - 1)]
        }
    }

    /// The highlight to keep after the board changes (a card moved, archived, filtered away): the same
    /// card if it's still shown, otherwise nothing.
    public static func retained(_ current: String?, columns: [[String]]) -> String? {
        guard let current, columns.contains(where: { $0.contains(current) }) else { return nil }
        return current
    }
}
