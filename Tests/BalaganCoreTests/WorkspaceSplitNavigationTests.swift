import XCTest
@testable import BalaganCore

final class WorkspaceSplitNavigationTests: XCTestCase {
    /// Resolve a destination pane to its first surface (the common case: panes are single surfaces).
    private func first(_ ids: [Surface.ID]) -> Surface.ID? { ids.first }

    private func neighbor(_ layout: WorkspaceLayout, _ from: Surface.ID, _ direction: SplitFocusDirection) -> Surface.ID? {
        layout.neighborSurface(of: from, direction: direction, representativeSurface: first)
    }

    func testDirectionAxisAndOrientation() {
        XCTAssertEqual(SplitFocusDirection.left.axis, .horizontal)
        XCTAssertEqual(SplitFocusDirection.right.axis, .horizontal)
        XCTAssertEqual(SplitFocusDirection.up.axis, .vertical)
        XCTAssertEqual(SplitFocusDirection.down.axis, .vertical)
        XCTAssertTrue(SplitFocusDirection.right.movesForward)
        XCTAssertTrue(SplitFocusDirection.down.movesForward)
        XCTAssertFalse(SplitFocusDirection.left.movesForward)
        XCTAssertFalse(SplitFocusDirection.up.movesForward)
    }

    func testHorizontalSplitLeftRight() {
        // A | B  (side by side)
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [.surface("A"), .surface("B")])
        XCTAssertEqual(neighbor(layout, "A", .right), "B")
        XCTAssertEqual(neighbor(layout, "B", .left), "A")
        // No wrap, and the perpendicular axis has no neighbor.
        XCTAssertNil(neighbor(layout, "A", .left))
        XCTAssertNil(neighbor(layout, "B", .right))
        XCTAssertNil(neighbor(layout, "A", .up))
        XCTAssertNil(neighbor(layout, "A", .down))
    }

    func testVerticalSplitUpDown() {
        // A over B (stacked)
        let layout = WorkspaceLayout.split(axis: .vertical, children: [.surface("A"), .surface("B")])
        XCTAssertEqual(neighbor(layout, "A", .down), "B")
        XCTAssertEqual(neighbor(layout, "B", .up), "A")
        XCTAssertNil(neighbor(layout, "A", .left))
        XCTAssertNil(neighbor(layout, "A", .right))
    }

    func testNestedSplitWalksUpToMatchingAxis() {
        // Root horizontal: [ A | (B over C) ]
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [
            .surface("A"),
            .split(axis: .vertical, children: [.surface("B"), .surface("C")]),
        ])
        // Within the vertical sub-split, up/down move between B and C.
        XCTAssertEqual(neighbor(layout, "B", .down), "C")
        XCTAssertEqual(neighbor(layout, "C", .up), "B")
        // Moving left from B or C crosses up to the root horizontal split → A.
        XCTAssertEqual(neighbor(layout, "B", .left), "A")
        XCTAssertEqual(neighbor(layout, "C", .left), "A")
        // Moving right from A enters the sub-split at its first (top) pane → B.
        XCTAssertEqual(neighbor(layout, "A", .right), "B")
        // No neighbor below C (it's the bottom of its column and A has no vertical sibling).
        XCTAssertNil(neighbor(layout, "C", .down))
    }

    func testThreePaneHorizontalRow() {
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [
            .surface("A"), .surface("B"), .surface("C"),
        ])
        XCTAssertEqual(neighbor(layout, "A", .right), "B")
        XCTAssertEqual(neighbor(layout, "B", .right), "C")
        XCTAssertEqual(neighbor(layout, "C", .left), "B")
        XCTAssertEqual(neighbor(layout, "B", .left), "A")
        XCTAssertNil(neighbor(layout, "C", .right))
    }

    func testTabsAndSingleHaveNoSpatialNeighbor() {
        XCTAssertNil(neighbor(.surface("A"), "A", .right))
        XCTAssertNil(neighbor(.tabs([.surface("A"), .surface("B")]), "A", .right))
        XCTAssertNil(neighbor(.single, "A", .right))
    }

    func testUnknownSurfaceReturnsNil() {
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [.surface("A"), .surface("B")])
        XCTAssertNil(neighbor(layout, "missing", .right))
    }

    func testWorkspaceConveniencePrefersSelectedSurface() {
        // Destination pane is a tabs node; representative should prefer the selected surface if present.
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [
            .surface("A"),
            .tabs([.surface("B"), .surface("C")]),
        ])
        var workspace = Workspace(id: "w", taskID: "t", layout: layout, selectedSurfaceID: "C", surfaces: [
            Surface(id: "A", workspaceID: "w", title: "A", cwd: "/"),
            Surface(id: "B", workspaceID: "w", title: "B", cwd: "/"),
            Surface(id: "C", workspaceID: "w", title: "C", cwd: "/"),
        ])
        // Moving right from A into the tabs pane lands on the selected tab (C), not just the first (B).
        XCTAssertEqual(workspace.neighborSurface(of: "A", direction: .right), "C")
        // With no selection in the destination pane, falls back to the first surface.
        workspace.selectedSurfaceID = "A"
        XCTAssertEqual(workspace.neighborSurface(of: "A", direction: .right), "B")
    }
}
