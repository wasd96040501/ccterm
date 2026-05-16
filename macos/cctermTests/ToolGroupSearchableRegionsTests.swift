import XCTest

@testable import ccterm

/// Unit tests for `ToolGroupLayout.selectionAdapter.searchableRegions` —
/// the entry point that lets in-transcript search reach tool-call body
/// content. Folded children produce no body in the layout, so they
/// contribute no searchable regions; expanded children are picked up.
///
/// `Transcript2SearchCoordinator` is layout-agnostic (it walks every
/// `SelectionAdapter.searchableRegions` regardless of block kind), so
/// these tests pin the contract at the lowest layer the search relies on.
@MainActor
final class ToolGroupSearchableRegionsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A bash child's stdout text appears in the adapter's searchable
    /// regions when both the group host and the child are expanded.
    /// Char offsets in the region's `text` round-trip through the
    /// region's `position` closure into `.textCard(...)` positions that
    /// match selection's own char encoding — the search-range ==
    /// selection-range invariant the search coordinator depends on.
    func testBashStdoutExpandedYieldsSearchableRegion() {
        let groupId = UUID()
        let bashId = UUID()
        let stdout = "apple banana\ncherry apple"
        let group = ToolGroupBlock(
            activeTitle: "Running command",
            expandedActiveTitle: "Running 1 command",
            completedTitle: "Ran 1 command",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'ls'",
                        activeLabel: "Running 'ls'",
                        command: "ls",
                        stdout: stdout,
                        stderr: nil))
            ])

        let layout = ToolGroupLayout.make(
            blockId: groupId,
            group: group,
            foldStates: [groupId: true, bashId: true],
            statusStates: [:],
            childHighlights: [:],
            maxWidth: 600)

        let adapter = layout.selectionAdapter
        XCTAssertNotNil(
            adapter,
            "expanded tool group with a non-empty body must publish a selection adapter")
        let regions = adapter?.searchableRegions() ?? []
        XCTAssertFalse(
            regions.isEmpty,
            "expanded bash child must expose searchable regions for its body cards")
        XCTAssertTrue(
            regions.contains(where: { $0.text.contains("apple") }),
            "bash stdout should appear inside one of the searchable regions")

        // The region's `position` closure must hand back `.textCard`
        // positions that the same adapter can render via `rects(...)`.
        // Without this, search hits would be discoverable in the scan
        // pass but invisible at draw time.
        let region = regions.first(where: { $0.text.contains("apple") })!
        let nsText = region.text as NSString
        let appleRange = nsText.range(of: "apple")
        XCTAssertNotEqual(appleRange.location, NSNotFound)
        let start = region.position(appleRange.location)
        let end = region.position(appleRange.location + appleRange.length)
        if case .textCard(let i, _, _) = start {
            XCTAssertEqual(
                i, 0,
                "first child's region must report childIndex 0; downstream nav uses this to expand the right child")
        } else {
            XCTFail("bash region position should be .textCard, got \(start)")
        }
        let rects = adapter!.rects(start, end)
        XCTAssertFalse(
            rects.isEmpty,
            "the position pair returned from `region.position` must produce non-empty rects through the same adapter")
    }

    /// Folded children carry no body in the layout, so they contribute
    /// nothing to `searchableRegions`. This matches the architectural
    /// invariant "search-range == selection-range": a folded child has
    /// nothing selectable, so nothing searchable.
    func testFoldedBashChildHasNoSearchableRegion() {
        let groupId = UUID()
        let bashId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Running command",
            expandedActiveTitle: "Running 1 command",
            completedTitle: "Ran 1 command",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'ls'",
                        activeLabel: "Running 'ls'",
                        command: "ls",
                        stdout: "apple banana",
                        stderr: nil))
            ])

        // Group expanded, child folded — the child's body never gets
        // laid out, so no region is built for it.
        let layout = ToolGroupLayout.make(
            blockId: groupId,
            group: group,
            foldStates: [groupId: true],
            statusStates: [:],
            childHighlights: [:],
            maxWidth: 600)

        XCTAssertNil(
            layout.selectionAdapter,
            "folded child means no regions → no selection adapter → search skips this block")
    }

    /// Group itself folded — the layout has zero entries and no regions
    /// at all, even when children would have been expandable.
    func testFoldedGroupHasNoSearchableRegion() {
        let groupId = UUID()
        let bashId = UUID()
        let group = ToolGroupBlock(
            activeTitle: "Running command",
            expandedActiveTitle: "Running 1 command",
            completedTitle: "Ran 1 command",
            children: [
                .bash(
                    BashChild(
                        id: bashId,
                        label: "Ran 'ls'",
                        activeLabel: "Running 'ls'",
                        command: "ls",
                        stdout: "apple banana",
                        stderr: nil))
            ])

        // Both folded — group has no entries, adapter is nil.
        let layout = ToolGroupLayout.make(
            blockId: groupId,
            group: group,
            foldStates: [:],
            statusStates: [:],
            childHighlights: [:],
            maxWidth: 600)

        XCTAssertNil(
            layout.selectionAdapter,
            "fully folded group means zero entries → no selection adapter")
    }
}
