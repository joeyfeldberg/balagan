import XCTest
@testable import BalaganCore

final class WorkspaceSerializationTests: XCTestCase {
    func testWorkspaceRoundTripsThroughJSON() throws {
        let primary = BalaganFixtures.surface(id: "surface-primary", title: "Primary")
        let secondary = BalaganFixtures.surface(
            id: "surface-secondary",
            title: "Secondary",
            resumeBinding: nil,
            scrollbackSnapshot: "secondary output"
        )
        // A tab that is a single pane, plus a tab that contains a split (the Ghostty shape).
        let workspace = Workspace(
            id: "workspace-split",
            taskID: "build-board",
            layout: .tabs([
                .surface(primary.id),
                .split(axis: .horizontal, children: [.surface(secondary.id), .surface(primary.id)]),
            ]),
            selectedSurfaceID: secondary.id,
            surfaces: [primary, secondary],
            lastOpenedAt: BalaganFixtures.laterDate
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.selectedSurface, secondary)
    }

    func testEachLayoutCaseRoundTrips() throws {
        let cases: [WorkspaceLayout] = [
            .single,
            .surface("a"),
            .tabs([.surface("a"), .surface("b")]),
            .split(axis: .vertical, children: [.surface("a"), .surface("b")]),
            .tabs([.surface("a"), .split(axis: .horizontal, children: [.surface("b"), .surface("c")])]),
        ]
        for layout in cases {
            let data = try JSONEncoder().encode(layout)
            XCTAssertEqual(try JSONDecoder().decode(WorkspaceLayout.self, from: data), layout)
        }
    }

    // MARK: - Backward compatibility with the legacy `.tabs([Surface.ID])` on-disk format

    func testDecodesLegacyTabsArrayOfStrings() throws {
        let legacy = #"{"tabs":{"_0":["a","b"]}}"#
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(legacy.utf8))
        XCTAssertEqual(layout, .tabs([.surface("a"), .surface("b")]))
    }

    func testDecodesLegacyInvertedSplitOfTabs() throws {
        // The old "inverted" shape: a split whose first child is a tab group.
        let legacy = #"{"split":{"axis":"horizontal","children":[{"tabs":{"_0":["a"]}},{"surface":{"_0":"b"}}]}}"#
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(legacy.utf8))
        XCTAssertEqual(layout, .split(axis: .horizontal, children: [.tabs([.surface("a")]), .surface("b")]))
    }

    // MARK: - Canonicalization to the Ghostty shape (root tabs, splits inside tabs)

    func testCanonicalizeKeepsAlreadyCanonicalLayout() {
        let layout = WorkspaceLayout.tabs([.surface("a"), .surface("b")])
        XCTAssertEqual(layout.canonicalized(), layout)
    }

    func testCanonicalizeWrapsBareSplitInOneTab() {
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [.surface("a"), .surface("b")])
        XCTAssertEqual(
            layout.canonicalized(),
            .tabs([.split(axis: .horizontal, children: [.surface("a"), .surface("b")])])
        )
    }

    func testCanonicalizeLiftsInvertedSplitOfTabsIntoOneTabWithASplit() {
        // The legacy inversion → one tab containing the split (the single inner tab collapses to a pane).
        let layout = WorkspaceLayout.split(axis: .horizontal, children: [.tabs([.surface("a")]), .surface("b")])
        XCTAssertEqual(
            layout.canonicalized(),
            .tabs([.split(axis: .horizontal, children: [.surface("a"), .surface("b")])])
        )
    }

    // MARK: - Ordered surfaces / tab indexing

    func testOrderedSurfaceIDsFollowSplitLayout() {
        let primary = BalaganFixtures.surface(id: "primary", title: "Primary")
        let secondary = BalaganFixtures.surface(id: "secondary", title: "Secondary")
        let tertiary = BalaganFixtures.surface(id: "tertiary", title: "Tertiary")
        let workspace = Workspace(
            id: "workspace-split",
            taskID: "build-board",
            layout: .tabs([
                .surface(primary.id),
                .split(axis: .vertical, children: [.surface(secondary.id), .surface(tertiary.id)]),
            ]),
            selectedSurfaceID: primary.id,
            surfaces: [primary, secondary, tertiary]
        )

        XCTAssertEqual(workspace.orderedSurfaceIDs, [primary.id, secondary.id, tertiary.id])
        XCTAssertEqual(workspace.lastSurfaceID, tertiary.id)
    }

    // MARK: - Splitting (within a tab; tabs stay at the root)

    func testSplittingFocusedSurfaceUpdatesOnlyContainingPane() throws {
        let layout = WorkspaceLayout.split(
            axis: .horizontal,
            children: [.surface("primary"), .surface("secondary")]
        )
        let splitLayout = try XCTUnwrap(layout.splittingSurface("secondary", axis: .horizontal, newSurfaceID: "tertiary"))
        XCTAssertEqual(
            splitLayout,
            .split(axis: .horizontal, children: [.surface("primary"), .surface("secondary"), .surface("tertiary")])
        )
    }

    func testSplittingASoloTabSplitsInsideThatTab() throws {
        let firstSplit = try XCTUnwrap(WorkspaceLayout.tabs([.surface("primary")])
            .splittingSurface("primary", axis: .horizontal, newSurfaceID: "secondary"))
        XCTAssertEqual(
            firstSplit,
            .tabs([.split(axis: .horizontal, children: [.surface("primary"), .surface("secondary")])])
        )

        // Splitting again in the same axis adds a peer pane inside the same tab.
        let secondSplit = try XCTUnwrap(firstSplit.splittingSurface("secondary", axis: .horizontal, newSurfaceID: "tertiary"))
        XCTAssertEqual(
            secondSplit,
            .tabs([.split(axis: .horizontal, children: [.surface("primary"), .surface("secondary"), .surface("tertiary")])])
        )
    }

    func testSplittingOneTabPreservesTheOtherTabs() throws {
        let layout = WorkspaceLayout.tabs([.surface("primary"), .surface("secondary")])
        let splitLayout = try XCTUnwrap(layout.splittingSurface("secondary", axis: .horizontal, newSurfaceID: "tertiary"))
        // "primary" stays a plain tab; only "secondary"'s tab becomes a split.
        XCTAssertEqual(
            splitLayout,
            .tabs([
                .surface("primary"),
                .split(axis: .horizontal, children: [.surface("secondary"), .surface("tertiary")]),
            ])
        )
    }

    func testAddingTabAppendsAtRootPreservingSplits() {
        let layout = WorkspaceLayout.tabs([.split(axis: .horizontal, children: [.surface("a"), .surface("b")])])
        XCTAssertEqual(
            layout.addingTab(.surface("c")),
            .tabs([.split(axis: .horizontal, children: [.surface("a"), .surface("b")]), .surface("c")])
        )
    }

    // MARK: - Tab strip shows one entry per tab, never split panes

    func testTabSurfaceIDsAreOneRepresentativePerTab() {
        let layout = WorkspaceLayout.tabs([
            .surface("primary"),
            .split(axis: .horizontal, children: [.surface("secondary"), .surface("tertiary")]),
        ])
        // Two tabs → two entries (the split's panes are not separate tabs).
        XCTAssertEqual(layout.tabSurfaceIDs(availableSurfaceIDs: ["primary", "secondary", "tertiary"]), ["primary", "secondary"])
        XCTAssertEqual(layout.orderedSurfaceIDs(availableSurfaceIDs: ["primary", "secondary", "tertiary"]), ["primary", "secondary", "tertiary"])
    }
}
