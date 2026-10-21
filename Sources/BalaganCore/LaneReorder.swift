import Foundation

/// Dragging a lane to a new place on the board.
public enum LaneReorder {
    /// Where a dragged lane lands, as an index among the *other* lanes: how many of them have their
    /// middle left of the point being dragged.
    public static func insertionIndex(dropX: Double, otherMidXs: [Double]) -> Int {
        otherMidXs.filter { $0 < dropX }.count
    }

    /// `items` with the one at `from` moved to `insertion` (an index among the remaining items).
    public static func moving<T>(_ items: [T], from: Int, to insertion: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var result = items
        let moved = result.remove(at: from)
        result.insert(moved, at: min(max(insertion, 0), result.count))
        return result
    }
}
