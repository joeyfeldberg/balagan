import Foundation

/// Dragging a lane on the board, or a project in the sidebar, to a new place.
public enum DragReorder {
    /// Where a dragged lane or sidebar row lands, as an index among the *other* items: how many of
    /// them have their middle before the point being dragged (along the drag's axis).
    public static func insertionIndex(dropAt position: Double, otherMidpoints: [Double]) -> Int {
        otherMidpoints.filter { $0 < position }.count
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
