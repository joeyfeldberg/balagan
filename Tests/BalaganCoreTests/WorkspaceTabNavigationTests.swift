import XCTest
@testable import BalaganCore

/// Tab navigation in the Ghostty model: tabs are the outer level, splits live inside a tab. Switching
/// tabs cycles whole tabs (never landing on a split pane); split focus moves between panes in the tab.
final class WorkspaceTabNavigationTests: XCTestCase {
    private func workspace(layout: WorkspaceLayout, surfaceIDs: [Surface.ID], selected: Surface.ID? = nil) -> Workspace {
        Workspace(
            id: "w",
            taskID: "t",
            layout: layout,
            selectedSurfaceID: selected,
            surfaces: surfaceIDs.map { Surface(id: $0, workspaceID: "w", title: $0, cwd: "/") }
        )
    }

    // MARK: - The tab strip shows one entry per tab

    func testTabSurfaceIDsAreOneRepresentativePerTab() {
        let layout = WorkspaceLayout.tabs([
            .surface("A"),
            .split(axis: .horizontal, children: [.surface("B"), .surface("C")]),
        ])
        // Two tabs → A and the split's first pane B; never C as a separate tab.
        XCTAssertEqual(layout.tabSurfaceIDs(availableSurfaceIDs: ["A", "B", "C"]), ["A", "B"])
    }

    func testBareSplitIsASingleTab() {
        // A non-canonical bare split reads as one tab (its representative is the first pane).
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [.surface("A"), .surface("B")])
        XCTAssertEqual(layout.tabSurfaceIDs(availableSurfaceIDs: ["A", "B"]), ["A"])
    }

    // MARK: - Switching tabs cycles whole tabs, from any pane within the tab

    func testTabNavigationCyclesTabs() {
        let layout = WorkspaceLayout.tabs([.surface("A"), .surface("B"), .surface("C")])
        let ws = workspace(layout: layout, surfaceIDs: ["A", "B", "C"], selected: "A")
        XCTAssertEqual(ws.tabSurfaceID(after: "A"), "B")
        XCTAssertEqual(ws.tabSurfaceID(after: "C"), "A") // wraps
        XCTAssertEqual(ws.tabSurfaceID(before: "A"), "C")
    }

    func testTabNavigationFromInsideASplitMovesToTheOtherTab() {
        // Tab 0 is a single pane; tab 1 contains a split of B|C.
        let layout = WorkspaceLayout.tabs([
            .surface("A"),
            .split(axis: .horizontal, children: [.surface("B"), .surface("C")]),
        ])
        let ws = workspace(layout: layout, surfaceIDs: ["A", "B", "C"], selected: "C")
        // From pane C (inside tab 1), next tab wraps to tab 0's representative A — never to a pane.
        XCTAssertEqual(ws.tabSurfaceID(after: "C"), "A")
        // From tab 0, next tab is tab 1's representative (its first pane), not its second pane.
        XCTAssertEqual(ws.tabSurfaceID(after: "A"), "B")
    }

    func testNonWrappingStopsAtEnds() {
        let layout = WorkspaceLayout.tabs([.surface("A"), .surface("B"), .surface("C")])
        let ws = workspace(layout: layout, surfaceIDs: ["A", "B", "C"], selected: "A")
        XCTAssertNil(ws.tabSurfaceID(after: "C", wrapping: false))
        XCTAssertNil(ws.tabSurfaceID(before: "A", wrapping: false))
        XCTAssertEqual(ws.tabSurfaceID(after: "A", wrapping: false), "B")
    }

    // MARK: - Split focus stays within the current tab

    func testSplitFocusMovesBetweenPanesOfTheCurrentTabOnly() {
        let layout = WorkspaceLayout.tabs([
            .surface("A"),
            .split(axis: .horizontal, children: [.surface("B"), .surface("C")]),
        ])
        let ws = workspace(layout: layout, surfaceIDs: ["A", "B", "C"], selected: "B")
        // Within tab 1, right/left move between B and C.
        XCTAssertEqual(ws.neighborSurface(of: "B", direction: .right), "C")
        XCTAssertEqual(ws.neighborSurface(of: "C", direction: .left), "B")
        // There's no pane to the left of B *within its tab* (tab 0 is a different tab, reached via tab nav).
        XCTAssertNil(ws.neighborSurface(of: "B", direction: .left))
        // The single-pane tab has no split neighbor.
        XCTAssertNil(ws.neighborSurface(of: "A", direction: .right))
    }

    /// A tab moves whole (its split comes along) and `surfaces` follows the new visual order.
    func testMoveTabKeepsSplitsAndReordersSurfaces() {
        let surfaces = ["a", "b", "c", "d"].map { BalaganFixtures.surface(id: $0, title: $0) }
        var workspace = BalaganFixtures.workspace(
            layout: .tabs([
                .surface("a"),
                .split(axis: .horizontal, children: [.surface("b"), .surface("c")]),
                .surface("d"),
            ]),
            selectedSurfaceID: "a",
            surfaces: surfaces
        )

        XCTAssertTrue(workspace.moveTab(from: 1, to: 2))
        XCTAssertEqual(workspace.layout, .tabs([
            .surface("a"),
            .surface("d"),
            .split(axis: .horizontal, children: [.surface("b"), .surface("c")]),
        ]))
        XCTAssertEqual(workspace.surfaces.map(\.id), ["a", "d", "b", "c"])

        XCTAssertTrue(workspace.moveTab(from: 0, to: 99), "clamps to the end")
        XCTAssertEqual(workspace.layout.tabContents.last, .surface("a"))
        XCTAssertFalse(workspace.moveTab(from: 7, to: 0))
    }
}
