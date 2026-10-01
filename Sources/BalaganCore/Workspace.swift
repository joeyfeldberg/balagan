import Foundation

public typealias WorkspaceSplitAxis = SplitAxis

public struct Workspace: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var taskID: TaskItem.ID
    public var layout: WorkspaceLayout
    public var selectedSurfaceID: Surface.ID?
    public var surfaces: [Surface]
    public var lastOpenedAt: Date?
    /// Persisted divider weights per split node, keyed by `WorkspaceLayout.splitKey`. A split with no
    /// stored weights (or whose pane arrangement changed) falls back to pane-count-proportional
    /// distribution, which is the "equalized" layout. Optional for backward-compatible decoding.
    public var splitWeights: [String: [Double]]?

    public init(
        id: String,
        taskID: TaskItem.ID,
        layout: WorkspaceLayout = .single,
        selectedSurfaceID: Surface.ID? = nil,
        surfaces: [Surface] = [],
        lastOpenedAt: Date? = nil,
        splitWeights: [String: [Double]]? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.layout = layout
        self.selectedSurfaceID = selectedSurfaceID
        self.surfaces = surfaces
        self.lastOpenedAt = lastOpenedAt
        self.splitWeights = splitWeights
    }
}

/// The layout of a task's terminal workspace, modeled on Ghostty (a task is a Ghostty *window*):
/// the root is `.tabs`, each tab is a **split tree** of panes. Tabs are always the outer level; a
/// `.split` only ever contains `.surface`/`.split` children — never `.tabs`. `.surface` is a single
/// pane; `.single` is the legacy/empty layout.
public indirect enum WorkspaceLayout: Equatable, Hashable, Sendable {
    case single
    /// Outer level: each child is one tab's content (a `.surface` or a `.split`).
    case tabs([WorkspaceLayout])
    case surface(Surface.ID)
    case split(axis: SplitAxis, children: [WorkspaceLayout])
}

extension WorkspaceLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case single, tabs, surface, split
    }

    private enum PayloadKeys: String, CodingKey {
        case _0 = "_0"
        case axis, children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.single) {
            self = .single
        } else if container.contains(.surface) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .surface)
            self = .surface(try payload.decode(Surface.ID.self, forKey: ._0))
        } else if container.contains(.tabs) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .tabs)
            // Legacy format encoded tabs as `[Surface.ID]`; the current format is `[WorkspaceLayout]`.
            if let legacyIDs = try? payload.decode([Surface.ID].self, forKey: ._0) {
                self = .tabs(legacyIDs.map { .surface($0) })
            } else {
                self = .tabs(try payload.decode([WorkspaceLayout].self, forKey: ._0))
            }
        } else if container.contains(.split) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .split)
            self = .split(
                axis: try payload.decode(SplitAxis.self, forKey: .axis),
                children: try payload.decode([WorkspaceLayout].self, forKey: .children)
            )
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized WorkspaceLayout"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .single:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .single)
        case .surface(let surfaceID):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .surface)
            try payload.encode(surfaceID, forKey: ._0)
        case .tabs(let tabs):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .tabs)
            try payload.encode(tabs, forKey: ._0)
        case .split(let axis, let children):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .split)
            try payload.encode(axis, forKey: .axis)
            try payload.encode(children, forKey: .children)
        }
    }
}

public enum SplitAxis: String, Codable, Equatable, Hashable, Sendable {
    case horizontal
    case vertical
}

extension Workspace {
    public var selectedSurface: Surface? {
        guard let selectedSurfaceID else {
            return nil
        }

        return surfaces.first { $0.id == selectedSurfaceID }
    }

    public var empty: Workspace {
        empty(forTaskID: taskID)
    }

    public func empty(forTaskID taskID: Task.ID) -> Workspace {
        Workspace(
            id: id,
            taskID: taskID,
            layout: .tabs([]),
            selectedSurfaceID: nil,
            surfaces: [],
            lastOpenedAt: lastOpenedAt
        )
    }

    public func surface(id surfaceID: Surface.ID) -> Surface? {
        surfaces.first { $0.id == surfaceID }
    }

    public var orderedSurfaceIDs: [Surface.ID] {
        layout.orderedSurfaceIDs(availableSurfaceIDs: surfaces.map(\.id))
    }

    public func surfaceID(after surfaceID: Surface.ID, wrapping: Bool = true) -> Surface.ID? {
        orderedSurfaceID(relativeTo: surfaceID, offset: 1, wrapping: wrapping)
    }

    public func surfaceID(before surfaceID: Surface.ID, wrapping: Bool = true) -> Surface.ID? {
        orderedSurfaceID(relativeTo: surfaceID, offset: -1, wrapping: wrapping)
    }

    public func surfaceID(atTabIndex index: Int) -> Surface.ID? {
        let orderedSurfaceIDs = orderedSurfaceIDs
        guard orderedSurfaceIDs.indices.contains(index) else {
            return nil
        }
        return orderedSurfaceIDs[index]
    }

    /// Next/previous **tab** surface — cycles only the tab surfaces (a `.tabs` group or a root single
    /// surface), never split panes (those are reached via split focus). If the current surface isn't a
    /// tab (e.g. it's a split pane), switches to the first tab.
    public func tabSurfaceID(after surfaceID: Surface.ID, wrapping: Bool = true) -> Surface.ID? {
        relativeTabSurfaceID(relativeTo: surfaceID, offset: 1, wrapping: wrapping)
    }

    public func tabSurfaceID(before surfaceID: Surface.ID, wrapping: Bool = true) -> Surface.ID? {
        relativeTabSurfaceID(relativeTo: surfaceID, offset: -1, wrapping: wrapping)
    }

    private func relativeTabSurfaceID(relativeTo surfaceID: Surface.ID, offset: Int, wrapping: Bool) -> Surface.ID? {
        let available = Set(surfaces.map(\.id))
        // The tabs that still have at least one live surface, switched by index so it works no matter
        // which pane within the current tab is focused.
        let tabs = layout.tabContents.filter { tab in tab.surfaceIDs().contains(where: available.contains) }
        guard tabs.isEmpty == false else {
            return nil
        }

        let currentTabIndex = tabs.firstIndex { $0.containsSurface(surfaceID) } ?? 0
        var targetIndex = currentTabIndex + offset
        if tabs.indices.contains(targetIndex) == false {
            guard wrapping else {
                return nil
            }
            targetIndex = offset > 0 ? 0 : tabs.count - 1
        }
        return tabs[targetIndex].surfaceIDs().first { available.contains($0) }
    }

    public var lastSurfaceID: Surface.ID? {
        orderedSurfaceIDs.last
    }

    /// Migrates the layout to the canonical Ghostty shape (root `.tabs`, splits inside tabs). Applied
    /// when loading persisted boards so legacy/“inverted” layouts render correctly.
    public mutating func canonicalizeLayout() {
        let canonical = layout.canonicalized()
        layout = canonical.surfaceIDs().isEmpty && surfaces.isEmpty == false
            ? .tabs(surfaces.map { .surface($0.id) })
            : canonical
    }

    public func deletingSurface(id surfaceID: Surface.ID) throws -> Workspace {
        var copy = self
        try copy.deleteSurface(id: surfaceID)
        return copy
    }

    @discardableResult
    public mutating func deleteSurface(id surfaceID: Surface.ID) throws -> Surface {
        guard let surfaceIndex = surfaces.firstIndex(where: { $0.id == surfaceID }) else {
            throw BoardStateMutationError.surfaceNotFound(surfaceID)
        }

        let previousOrderedSurfaceIDs = orderedSurfaceIDs
        let previousSelectedSurfaceID = selectedSurfaceID
        let removed = surfaces.remove(at: surfaceIndex)
        normalizeAfterSurfaceChange(
            deletedSurfaceID: surfaceID,
            previousOrderedSurfaceIDs: previousOrderedSurfaceIDs,
            previousSelectedSurfaceID: previousSelectedSurfaceID
        )
        return removed
    }

    public func normalizedAfterSurfaceChange(deletedSurfaceID: Surface.ID? = nil) -> Workspace {
        var copy = self
        copy.normalizeAfterSurfaceChange(deletedSurfaceID: deletedSurfaceID)
        return copy
    }

    public mutating func normalizeAfterSurfaceChange(deletedSurfaceID: Surface.ID? = nil) {
        normalizeAfterSurfaceChange(
            deletedSurfaceID: deletedSurfaceID,
            previousOrderedSurfaceIDs: nil,
            previousSelectedSurfaceID: nil
        )
    }

    private mutating func normalizeAfterSurfaceChange(
        deletedSurfaceID: Surface.ID?,
        previousOrderedSurfaceIDs: [Surface.ID]?,
        previousSelectedSurfaceID: Surface.ID?
    ) {
        let surfaceIDs = surfaces.map(\.id)
        layout = layout.pruningUnavailableSurfaceIDs(surfaceIDs) ?? .tabs(surfaceIDs.map { .surface($0) })

        guard !surfaceIDs.isEmpty else {
            selectedSurfaceID = nil
            return
        }

        if let selectedSurfaceID,
           selectedSurfaceID != deletedSurfaceID,
           surfaceIDs.contains(selectedSurfaceID) {
            return
        }

        selectedSurfaceID = replacementSurfaceID(
            afterDeleting: deletedSurfaceID ?? previousSelectedSurfaceID,
            previousOrderedSurfaceIDs: previousOrderedSurfaceIDs,
            availableSurfaceIDs: surfaceIDs
        )
    }

    private func replacementSurfaceID(
        afterDeleting deletedSurfaceID: Surface.ID?,
        previousOrderedSurfaceIDs: [Surface.ID]?,
        availableSurfaceIDs: [Surface.ID]
    ) -> Surface.ID? {
        guard let deletedSurfaceID,
              let previousOrderedSurfaceIDs,
              let deletedIndex = previousOrderedSurfaceIDs.firstIndex(of: deletedSurfaceID)
        else {
            return availableSurfaceIDs.first
        }

        let trailingSurfaceIDs = previousOrderedSurfaceIDs.dropFirst(deletedIndex + 1)
        if let next = trailingSurfaceIDs.first(where: { availableSurfaceIDs.contains($0) }) {
            return next
        }

        let leadingSurfaceIDs = previousOrderedSurfaceIDs.prefix(deletedIndex).reversed()
        if let previous = leadingSurfaceIDs.first(where: { availableSurfaceIDs.contains($0) }) {
            return previous
        }

        return availableSurfaceIDs.first
    }

    private func orderedSurfaceID(relativeTo surfaceID: Surface.ID, offset: Int, wrapping: Bool) -> Surface.ID? {
        let orderedSurfaceIDs = orderedSurfaceIDs
        guard orderedSurfaceIDs.isEmpty == false,
              let currentIndex = orderedSurfaceIDs.firstIndex(of: surfaceID)
        else {
            return nil
        }

        let nextIndex = currentIndex + offset
        if orderedSurfaceIDs.indices.contains(nextIndex) {
            return orderedSurfaceIDs[nextIndex]
        }

        guard wrapping else {
            return nil
        }

        return offset > 0 ? orderedSurfaceIDs.first : orderedSurfaceIDs.last
    }
}

extension WorkspaceLayout {
    /// The tabs at the root, as their content sub-layouts. A non-`.tabs` root is treated as a single
    /// tab; `.single` has none.
    public var tabContents: [WorkspaceLayout] {
        switch self {
        case .tabs(let tabs):
            return tabs
        case .single:
            return []
        case .surface, .split:
            return [self]
        }
    }

    /// All leaf surface IDs, in reading order.
    public func surfaceIDs() -> [Surface.ID] {
        switch self {
        case .single:
            return []
        case .surface(let surfaceID):
            return [surfaceID]
        case .tabs(let children), .split(_, let children):
            return children.flatMap { $0.surfaceIDs() }
        }
    }

    /// The first leaf surface — a tab's representative surface (used for its tab-bar entry).
    public var firstSurfaceID: Surface.ID? {
        surfaceIDs().first
    }

    public func containsSurface(_ surfaceID: Surface.ID) -> Bool {
        surfaceIDs().contains(surfaceID)
    }

    /// Appends a new tab (its content sub-layout) at the root, preserving existing tabs and their
    /// splits. Used by "new tab".
    public func addingTab(_ tab: WorkspaceLayout) -> WorkspaceLayout {
        .tabs(tabContents + [tab])
    }

    /// One representative surface per tab — what the tab strip shows. Falls back to every surface for a
    /// degenerate layout that places nothing (e.g. `.single`).
    public func tabSurfaceIDs(availableSurfaceIDs: [Surface.ID]) -> [Surface.ID] {
        let available = Set(availableSurfaceIDs)
        let representatives = tabContents.compactMap { tab in
            tab.surfaceIDs().first { available.contains($0) }
        }
        guard representatives.isEmpty else {
            return representatives
        }
        let placedSurfaceIDs = surfaceIDs().filter { available.contains($0) }
        return placedSurfaceIDs.isEmpty ? availableSurfaceIDs : []
    }

    /// Splits the pane holding `surfaceID` **within its tab** — tabs stay at the root, the split lives
    /// inside the containing tab. Same-axis splits merge into peer panes.
    public func splittingSurface(
        _ surfaceID: Surface.ID,
        axis: WorkspaceSplitAxis,
        newSurfaceID: Surface.ID
    ) -> WorkspaceLayout? {
        switch self {
        case .single:
            return nil
        case .surface(let existingSurfaceID):
            guard existingSurfaceID == surfaceID else {
                return nil
            }
            return .split(axis: axis, children: [.surface(existingSurfaceID), .surface(newSurfaceID)])
        case .tabs(let tabs):
            for (index, tab) in tabs.enumerated() {
                guard let updatedTab = tab.splittingSurface(surfaceID, axis: axis, newSurfaceID: newSurfaceID) else {
                    continue
                }
                var updatedTabs = tabs
                updatedTabs[index] = updatedTab
                return .tabs(updatedTabs)
            }
            return nil
        case .split(let existingAxis, let children):
            for (index, child) in children.enumerated() {
                guard let splitChild = child.splittingSurface(surfaceID, axis: axis, newSurfaceID: newSurfaceID) else {
                    continue
                }

                var updatedChildren = children
                if existingAxis == axis,
                   case .split(axis, let splitChildren) = splitChild {
                    updatedChildren.replaceSubrange(index ... index, with: splitChildren)
                } else {
                    updatedChildren[index] = splitChild
                }
                return .split(axis: existingAxis, children: updatedChildren)
            }
            return nil
        }
    }

    public func pruningUnavailableSurfaceIDs(_ availableSurfaceIDs: [Surface.ID]) -> WorkspaceLayout? {
        let available = Set(availableSurfaceIDs)
        return pruningUnavailableSurfaceIDs(available)
    }

    public func orderedSurfaceIDs(availableSurfaceIDs: [Surface.ID]) -> [Surface.ID] {
        let available = Set(availableSurfaceIDs)
        let orderedIDs = surfaceIDs().filter { available.contains($0) }
        guard orderedIDs.isEmpty == false else {
            return availableSurfaceIDs
        }
        return orderedIDs
    }

    /// Rewrites any layout into the canonical Ghostty shape: root `.tabs`, each tab a pure pane tree
    /// (`.surface`/`.split` only). Migrates legacy/“inverted” layouts (tabs nested inside a split) by
    /// lifting tabs to the root and turning a multi-tab group that was trapped inside a split into a
    /// split of its panes — lossless on surfaces. Empty tabs are dropped.
    public func canonicalized() -> WorkspaceLayout {
        let tabs = tabContents
            .map { $0.purifiedPane() }
            .filter { $0.surfaceIDs().isEmpty == false }
        return .tabs(tabs)
    }

    /// Collapses a sub-layout into a pure pane tree (no `.tabs`): a nested tab group becomes its single
    /// pane, or a horizontal split of its panes when it held more than one.
    private func purifiedPane() -> WorkspaceLayout {
        switch self {
        case .single:
            return .single
        case .surface:
            return self
        case .tabs(let children):
            let panes = children.map { $0.purifiedPane() }.filter { $0.surfaceIDs().isEmpty == false }
            if panes.count == 1 {
                return panes[0]
            }
            return .split(axis: .horizontal, children: panes)
        case .split(let axis, let children):
            return .split(axis: axis, children: children.map { $0.purifiedPane() })
        }
    }

    private func pruningUnavailableSurfaceIDs(_ availableSurfaceIDs: Set<Surface.ID>) -> WorkspaceLayout? {
        switch self {
        case .single:
            return nil
        case .surface(let surfaceID):
            return availableSurfaceIDs.contains(surfaceID) ? .surface(surfaceID) : nil
        case .tabs(let tabs):
            let prunedTabs = tabs.compactMap { $0.pruningUnavailableSurfaceIDs(availableSurfaceIDs) }
            return prunedTabs.isEmpty ? nil : .tabs(prunedTabs)
        case .split(let axis, let children):
            let prunedChildren = children.compactMap { $0.pruningUnavailableSurfaceIDs(availableSurfaceIDs) }
            if prunedChildren.count == 1 {
                return prunedChildren[0]
            }
            if prunedChildren.isEmpty {
                return nil
            }
            return .split(axis: axis, children: prunedChildren)
        }
    }
}
