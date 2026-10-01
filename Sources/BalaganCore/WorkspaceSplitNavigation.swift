import Foundation

/// A direction for moving keyboard focus between split panes (Ghostty's `goto_split`).
public enum SplitFocusDirection: String, Sendable, Equatable, CaseIterable {
    case left
    case right
    case up
    case down

    /// The split axis this direction moves along. Per the layout model, a `horizontal` split lays its
    /// children **side by side** (so left/right move between them); a `vertical` split **stacks** them
    /// (so up/down move between them).
    public var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// Whether this direction moves toward a *higher* child index (right/down) vs lower (left/up).
    public var movesForward: Bool {
        self == .right || self == .down
    }
}

extension WorkspaceLayout {
    /// The surface that is the spatial neighbor of `surfaceID` in `direction`, treating each non-split
    /// node (`.surface` / `.tabs` / `.single`) as one pane. Walks up the split tree to the nearest
    /// ancestor split whose axis matches the direction and that has a sibling pane that way, then
    /// descends to that sibling's edge-most pane. `representativeSurface` turns the destination pane's
    /// surface IDs into the concrete surface to focus (e.g. its visible tab). Returns nil if there is
    /// no neighbor in that direction.
    public func neighborSurface(
        of surfaceID: Surface.ID,
        direction: SplitFocusDirection,
        representativeSurface: (_ paneSurfaceIDs: [Surface.ID]) -> Surface.ID?
    ) -> Surface.ID? {
        guard var path = panePath(to: surfaceID, path: []) else {
            return nil
        }
        while let childIndex = path.last {
            path.removeLast()
            guard case let .split(axis, children) = node(atPath: path) else {
                break
            }
            if axis == direction.axis {
                let siblingIndex = direction.movesForward ? childIndex + 1 : childIndex - 1
                if children.indices.contains(siblingIndex) {
                    let pane = children[siblingIndex].edgePaneSurfaceIDs(enteringForward: direction.movesForward)
                    if let surface = representativeSurface(pane) {
                        return surface
                    }
                }
            }
        }
        return nil
    }

    /// Path of split-child indices from the root to the (non-split) pane containing `surfaceID`.
    func panePath(to surfaceID: Surface.ID, path: [Int]) -> [Int]? {
        switch self {
        case .single:
            return nil
        case .surface(let id):
            return id == surfaceID ? path : nil
        case .tabs(let children):
            // A tabs node is a leaf pane for split navigation (tabs don't nest inside a tab's splits).
            return children.contains { $0.containsSurface(surfaceID) } ? path : nil
        case .split(_, let children):
            for (index, child) in children.enumerated() {
                if let found = child.panePath(to: surfaceID, path: path + [index]) {
                    return found
                }
            }
            return nil
        }
    }

    /// The node reached by following `path` (split-child indices) from this node.
    private func node(atPath path: [Int]) -> WorkspaceLayout {
        var node = self
        for index in path {
            guard case let .split(_, children) = node, children.indices.contains(index) else {
                return node
            }
            node = children[index]
        }
        return node
    }

    /// Surface IDs of the edge-most pane when entering this subtree from a given direction: entering
    /// "forward" (moving right/down into it) lands on the first child; entering backward lands on the last.
    private func edgePaneSurfaceIDs(enteringForward: Bool) -> [Surface.ID] {
        switch self {
        case .single:
            return []
        case .surface(let id):
            return [id]
        case .tabs(let children):
            return children.flatMap { $0.surfaceIDs() }
        case .split(_, let children):
            guard let child = enteringForward ? children.first : children.last else {
                return []
            }
            return child.edgePaneSurfaceIDs(enteringForward: enteringForward)
        }
    }
}

extension Workspace {
    /// The neighbor surface to focus when moving in `direction` from `surfaceID`. Resolves a destination
    /// pane to its currently-selected surface when possible, otherwise its first surface.
    public func neighborSurface(of surfaceID: Surface.ID, direction: SplitFocusDirection) -> Surface.ID? {
        // Split focus stays within the surface's own tab (tabs are the outer level, splits live inside).
        guard let tab = layout.tabContents.first(where: { $0.containsSurface(surfaceID) }) else {
            return nil
        }
        return tab.neighborSurface(of: surfaceID, direction: direction) { paneSurfaceIDs in
            if let selectedSurfaceID, paneSurfaceIDs.contains(selectedSurfaceID) {
                return selectedSurfaceID
            }
            return paneSurfaceIDs.first
        }
    }
}
