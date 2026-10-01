import Foundation

// Ratio-driven split sizing (modeled on cmux's SplitEqualizer / Ghostty's equalize_splits):
// a split's children are sized from explicit weights, never from leftover space. Default and
// "equalize" weights are proportional to each child's pane count (leaf count), so every pane ends
// up the same size regardless of nesting. Manual divider drags persist as custom weights until the
// split's pane arrangement changes (then it re-balances).

extension WorkspaceLayout {
    /// Surface ids contained in this node, in layout order. Used as a stable key for a split's
    /// current pane arrangement.
    public var orderedLeafSurfaceIDs: [Surface.ID] {
        switch self {
        case .single:
            return []
        case .surface(let id):
            return [id]
        case .tabs(let children):
            return children.flatMap { $0.orderedLeafSurfaceIDs }
        case .split(_, let children):
            return children.flatMap { $0.orderedLeafSurfaceIDs }
        }
    }

    /// Number of leaf pane-slots under this node.
    public var paneSpanCount: Int {
        switch self {
        case .single:
            return 0
        case .surface:
            return 1
        case .tabs(let children), .split(_, let children):
            return children.reduce(0) { $0 + $1.paneSpanCount }
        }
    }

    /// Stable identity for a split node's current arrangement.
    public var splitKey: String {
        orderedLeafSurfaceIDs.joined(separator: "|")
    }

    /// Pane-count-proportional weights for this split's children (the equalized distribution).
    /// Returns `[]` for non-split nodes.
    public func spanProportionalWeights() -> [Double] {
        guard case .split(_, let children) = self else {
            return []
        }
        let counts = children.map { Double(max(1, $0.paneSpanCount)) }
        let total = counts.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1.0 / Double(max(1, children.count)), count: children.count)
        }
        return counts.map { $0 / total }
    }
}

extension Workspace {
    /// Divider weights to render `node`'s children with: persisted custom weights if present and
    /// still matching the child count, otherwise the equalized (pane-count-proportional) weights.
    public func weights(forSplit node: WorkspaceLayout) -> [Double] {
        guard case .split(_, let children) = node, children.isEmpty == false else {
            return []
        }
        if let stored = splitWeights?[node.splitKey], stored.count == children.count {
            return WorkspaceLayout.normalizedWeights(stored)
        }
        return node.spanProportionalWeights()
    }

    /// Records a manual divider adjustment for a split node, keyed by its `splitKey`.
    public mutating func setSplitWeights(_ weights: [Double], forKey key: String) {
        guard key.isEmpty == false, weights.isEmpty == false else {
            return
        }
        var dict = splitWeights ?? [:]
        dict[key] = WorkspaceLayout.normalizedWeights(weights)
        splitWeights = dict
    }

    /// Equalize Splits: drop all custom weights so every split renders pane-count-proportional.
    public mutating func equalizeSplits() {
        splitWeights = nil
    }
}

extension WorkspaceLayout {
    /// Clamps weights to be positive and sum to 1.
    static func normalizedWeights(_ weights: [Double]) -> [Double] {
        let floored = weights.map { max(0.05, $0) }
        let total = floored.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1.0 / Double(max(1, weights.count)), count: weights.count)
        }
        return floored.map { $0 / total }
    }
}
