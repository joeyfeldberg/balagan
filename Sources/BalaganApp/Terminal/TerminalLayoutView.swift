import AppKit
import SwiftUI
import BalaganCore

struct TerminalLayoutView: View {
    let taskID: TaskItem.ID
    let workspace: Workspace
    let activeSurface: Surface
    let zoomedSurfaceID: Surface.ID?
    let onSelectSurface: (Surface.ID) -> Void
    let onEndedProcessSurface: (TaskItem.ID, Surface.ID) -> Void
    let shortcuts: TerminalShortcutContext

    var body: some View {
        if let zoomedSurfaceID,
           let surface = surface(for: zoomedSurfaceID) {
            surfacePane(surface: surface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("terminal-zoomed-pane-\(surface.id)")
        } else {
            render(layout: workspace.layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func render(layout: WorkspaceLayout) -> AnyView {
        switch layout {
        case .single:
            return AnyView(surfacePane(surface: activeSurface))
        case .surface(let surfaceID):
            if let surface = surface(for: surfaceID) {
                return AnyView(surfacePane(surface: surface))
            } else {
                return AnyView(surfacePane(surface: activeSurface))
            }
        case .tabs(let tabs):
            // Each tab is its own split tree. Show the current tab (the one holding the active surface);
            // keep the others mounted but hidden so their terminals stay alive (cmux/Ghostty-style).
            let renderableTabs = tabs.filter { tab in tab.surfaceIDs().contains { surface(for: $0) != nil } }
            guard renderableTabs.isEmpty == false else {
                return AnyView(surfacePane(surface: activeSurface))
            }
            let currentIndex = renderableTabs.firstIndex { $0.containsSurface(activeSurface.id) } ?? 0
            return AnyView(ZStack {
                ForEach(Array(renderableTabs.enumerated()), id: \.element) { index, tab in
                    render(layout: tab)
                        .opacity(index == currentIndex ? 1 : 0)
                        .allowsHitTesting(index == currentIndex)
                        .accessibilityHidden(index != currentIndex)
                        .zIndex(index == currentIndex ? 1 : 0)
                }
            })
        case .split(let axis, let children):
            if children.isEmpty {
                return AnyView(surfacePane(surface: activeSurface))
            }
            let node = layout
            let key = node.splitKey
            let weights = workspace.weights(forSplit: node)
            let childViews = children.map { render(layout: $0) }
            let taskID = taskID
            return AnyView(ResizableSplit(
                axis: axis,
                weights: weights,
                children: childViews,
                onWeightsChanged: { newWeights in
                    TerminalHostRegistry.shared.splitWeightReporter?(taskID, key, newWeights)
                }
            ))
        }
    }

    private func surface(for surfaceID: Surface.ID) -> Surface? {
        workspace.surfaces.first { $0.id == surfaceID }
    }

    private func surfacePane(surface: Surface) -> some View {
        TerminalPane(
            taskID: taskID,
            surface: surface,
            isActive: surface.id == activeSurface.id,
            shortcuts: shortcuts,
            onActivate: {
                onSelectSurface(surface.id)
                TerminalHostRegistry.shared.focus(taskID: taskID, surfaceID: surface.id)
            },
            onEndedProcessSurface: onEndedProcessSurface
        )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectSurface(surface.id)
                TerminalHostRegistry.shared.focus(taskID: taskID, surfaceID: surface.id)
            }
            .accessibilityIdentifier("terminal-pane-\(surface.id)")
    }

}

/// Weight-driven split container: children are sized from explicit weights (never leftover space),
/// so a layout is always proportional. Dividers drag to update weights, committed on release.
private struct ResizableSplit: View {
    let axis: SplitAxis
    let weights: [Double]
    let children: [AnyView]
    let onWeightsChanged: ([Double]) -> Void

    private let dividerThickness: CGFloat = 1
    private let dividerHitThickness: CGFloat = 12

    @State private var liveWeights: [Double]?
    @State private var dragBase: [Double]?

    var body: some View {
        GeometryReader { geo in
            let count = children.count
            let current = Self.normalize(liveWeights ?? weights, count: count)
            let totalLength = axis == .horizontal ? geo.size.width : geo.size.height
            let contentLength = max(1, totalLength - dividerThickness * CGFloat(max(0, count - 1)))
            let sizes = current.map { max(CGFloat(1), CGFloat($0) * contentLength) }

            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) { panes(sizes: sizes, contentLength: contentLength) }
                } else {
                    VStack(spacing: 0) { panes(sizes: sizes, contentLength: contentLength) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func panes(sizes: [CGFloat], contentLength: CGFloat) -> some View {
        ForEach(0 ..< children.count, id: \.self) { i in
            child(i, size: sizes[i])
            if i < children.count - 1 {
                divider(afterIndex: i, contentLength: contentLength)
            }
        }
    }

    @ViewBuilder
    private func child(_ i: Int, size: CGFloat) -> some View {
        if axis == .horizontal {
            children[i].frame(width: size).frame(maxHeight: .infinity)
        } else {
            children[i].frame(height: size).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func divider(afterIndex i: Int, contentLength: CGFloat) -> some View {
        // A 1pt hairline that's visible, with a wider transparent hit area (overflowing the line) so
        // it's still easy to grab and resize.
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(
                width: axis == .horizontal ? dividerThickness : nil,
                height: axis == .vertical ? dividerThickness : nil
            )
            .frame(
                maxWidth: axis == .horizontal ? nil : .infinity,
                maxHeight: axis == .vertical ? nil : .infinity
            )
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: axis == .horizontal ? dividerHitThickness : nil,
                        height: axis == .vertical ? dividerHitThickness : nil
                    )
                    .frame(
                        maxWidth: axis == .horizontal ? nil : .infinity,
                        maxHeight: axis == .vertical ? nil : .infinity
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragBase ?? Self.normalize(weights, count: children.count)
                                if dragBase == nil { dragBase = base }
                                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                                liveWeights = Self.adjusted(base, at: i, by: Double(translation / contentLength))
                            }
                            .onEnded { value in
                                let base = dragBase ?? Self.normalize(weights, count: children.count)
                                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                                let final = Self.adjusted(base, at: i, by: Double(translation / contentLength))
                                dragBase = nil
                                liveWeights = nil
                                onWeightsChanged(final)
                            }
                    )
            }
    }

    private static func adjusted(_ weights: [Double], at i: Int, by delta: Double) -> [Double] {
        guard weights.indices.contains(i), weights.indices.contains(i + 1) else {
            return weights
        }
        var result = weights
        let minimum = 0.05
        let pair = result[i] + result[i + 1]
        let first = min(max(minimum, result[i] + delta), pair - minimum)
        result[i] = first
        result[i + 1] = pair - first
        return result
    }

    private static func normalize(_ weights: [Double], count: Int) -> [Double] {
        guard weights.count == count, count > 0 else {
            return Array(repeating: 1.0 / Double(max(1, count)), count: count)
        }
        let floored = weights.map { max(0.0001, $0) }
        let total = floored.reduce(0, +)
        return total > 0 ? floored.map { $0 / total } : Array(repeating: 1.0 / Double(count), count: count)
    }
}
