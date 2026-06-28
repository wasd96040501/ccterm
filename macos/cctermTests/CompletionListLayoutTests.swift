import XCTest

@testable import ccterm

/// CI-gate logic test (NOT a `*SnapshotTests` file → runs on the default suite
/// as the merge gate) for `CompletionListLayout` (migration plan §4.3, §9).
/// Drives the pure-math `listHeight(...)` / `displayCount(...)` directly and
/// asserts the 4 render branches are pixel-exact against the deleted-soon
/// SwiftUI `CompletionListView.listHeight` (lines 216-227) — the parity bar.
final class CompletionListLayoutTests: XCTestCase {

    // MARK: - Constants are the verbatim SwiftUI values

    func testConstantsMatchSwiftUISource() {
        XCTAssertEqual(CompletionListLayout.rowHeight, 24)
        XCTAssertEqual(CompletionListLayout.verticalInset, 4)
        XCTAssertEqual(CompletionListLayout.maxVisibleItems, 10)
        XCTAssertEqual(CompletionListLayout.detailLineHeight, 15)
        XCTAssertEqual(CompletionListLayout.detailBottomPadding, 6)
        // detailBlockHeight = 15*2 + 6 = 36 (reserved at EXACTLY two lines).
        XCTAssertEqual(CompletionListLayout.detailBlockHeight, 36)
    }

    // MARK: - listHeight: the 4 branches (pixel-exact)

    /// B1 — header + items empty → header-only, NO empty placeholder
    /// (displayCount 0). listHeight = 24 + 0 + 0 + 8 = 32.
    func testListHeight_B1_headerEmpty() {
        let count = CompletionListLayout.displayCount(
            headerPresent: true, itemCount: 0, isLoading: false)
        XCTAssertEqual(count, 0, "header + empty → displayCount 0 (no placeholder).")
        let h = CompletionListLayout.listHeight(
            headerPresent: true, displayCount: count, hasSelectedDetail: false)
        XCTAssertEqual(h, 32, "B1 header+empty must be 24+0+0+8 = 32.")
    }

    /// B2 — no header + empty + loading → single Loading row.
    /// listHeight = 0 + 24 + 0 + 8 = 32.
    func testListHeight_B2_emptyLoading() {
        let count = CompletionListLayout.displayCount(
            headerPresent: false, itemCount: 0, isLoading: true)
        XCTAssertEqual(count, 1, "no header + empty + loading → one Loading row.")
        let h = CompletionListLayout.listHeight(
            headerPresent: false, displayCount: count, hasSelectedDetail: false)
        XCTAssertEqual(h, 32, "B2 empty+loading must be 0+24+0+8 = 32.")
    }

    /// B3 — no header + empty + !loading → single empty row (noMatches /
    /// noDirectory). listHeight = 0 + 24 + 0 + 8 = 32.
    func testListHeight_B3_emptyNoMatches() {
        let count = CompletionListLayout.displayCount(
            headerPresent: false, itemCount: 0, isLoading: false)
        XCTAssertEqual(count, 1, "no header + empty + !loading → one empty row.")
        let h = CompletionListLayout.listHeight(
            headerPresent: false, displayCount: count, hasSelectedDetail: false)
        XCTAssertEqual(h, 32, "B3 empty+noMatches must be 0+24+0+8 = 32.")
    }

    /// B4a — 3 items, no detail, no header. listHeight = 0 + 72 + 0 + 8 = 80.
    func testListHeight_B4a_threeItemsNoDetailNoHeader() {
        let count = CompletionListLayout.displayCount(
            headerPresent: false, itemCount: 3, isLoading: false)
        XCTAssertEqual(count, 3)
        let h = CompletionListLayout.listHeight(
            headerPresent: false, displayCount: count, hasSelectedDetail: false)
        XCTAssertEqual(h, 80, "B4a 3 items no detail no header must be 0+72+0+8 = 80.")
    }

    /// B4b — 3 items + selected has detail + no header.
    /// listHeight = 0 + 72 + 36 + 8 = 116.
    func testListHeight_B4b_threeItemsSelectedDetailNoHeader() {
        let count = CompletionListLayout.displayCount(
            headerPresent: false, itemCount: 3, isLoading: false)
        let h = CompletionListLayout.listHeight(
            headerPresent: false, displayCount: count, hasSelectedDetail: true)
        XCTAssertEqual(h, 116, "B4b 3 items + detail must be 0+72+36+8 = 116.")
    }

    /// B4c — header + 12 items (clamp to 10) + detail.
    /// listHeight = 24 + 240 + 36 + 8 = 308.
    func testListHeight_B4c_headerTwelveItemsClampDetail() {
        let count = CompletionListLayout.displayCount(
            headerPresent: true, itemCount: 12, isLoading: false)
        XCTAssertEqual(count, 10, "12 items clamp to maxVisibleItems (10).")
        let h = CompletionListLayout.listHeight(
            headerPresent: true, displayCount: count, hasSelectedDetail: true)
        XCTAssertEqual(h, 308, "B4c header + 10 clamped rows + detail must be 24+240+36+8 = 308.")
    }

    // MARK: - displayCount table (clamp + branch selection)

    func testDisplayCountTable() {
        // (header present, items empty) → 0 regardless of loading.
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: true, itemCount: 0, isLoading: false), 0)
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: true, itemCount: 0, isLoading: true), 0)
        // (no header, empty, loading) → 1.
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: false, itemCount: 0, isLoading: true), 1)
        // (no header, empty, !loading) → 1.
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: false, itemCount: 0, isLoading: false), 1)
        // (no header, 5 items) → 5.
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: false, itemCount: 5, isLoading: false), 5)
        // (no header, 15 items) → clamp to 10.
        XCTAssertEqual(CompletionListLayout.displayCount(headerPresent: false, itemCount: 15, isLoading: false), 10)
        // contentH for 15 items is 10 * 24 = 240 (clamp).
        let count15 = CompletionListLayout.displayCount(headerPresent: false, itemCount: 15, isLoading: false)
        XCTAssertEqual(CGFloat(count15) * CompletionListLayout.rowHeight, 240)
    }

    // MARK: - cleanedDetail / selectedDetail folding

    func testCleanedDetailFoldsWhitespace() {
        XCTAssertNil(CompletionListLayout.cleanedDetail(nil))
        XCTAssertNil(CompletionListLayout.cleanedDetail("   \n\t  "), "All-whitespace folds to nil.")
        XCTAssertEqual(
            CompletionListLayout.cleanedDetail("  Review the\tdiff\nfor bugs.  "),
            "Review the diff for bugs.",
            "Whitespace runs (incl. \\n \\t) fold to single spaces; trimmed.")
    }

    func testSelectedDetailDrivesDetailH() {
        let items: [any CompletionItem] = [
            SlashCommandStore.Match(name: "commit", description: "Create a commit", rank: 0),
            SlashCommandStore.Match(name: "review", description: nil, rank: 1),
        ]
        // Index 0 has a description → detail present.
        XCTAssertEqual(
            CompletionListLayout.selectedDetail(items: items, selectedIndex: 0),
            "Create a commit")
        // Index 1 has nil description → no detail.
        XCTAssertNil(CompletionListLayout.selectedDetail(items: items, selectedIndex: 1))
        // Out-of-range → nil.
        XCTAssertNil(CompletionListLayout.selectedDetail(items: items, selectedIndex: -1))
        XCTAssertNil(CompletionListLayout.selectedDetail(items: items, selectedIndex: 5))
    }

    // MARK: - textLeading (column alignment)

    func testTextLeading() {
        // text-only (slash command): no icon, no badge → 13.
        XCTAssertEqual(CompletionListLayout.textLeading(hasIcon: false, hasBadge: false), 13)
        // badge present (file with sourceDir) → 4.
        XCTAssertEqual(CompletionListLayout.textLeading(hasIcon: true, hasBadge: true), 4)
        XCTAssertEqual(CompletionListLayout.textLeading(hasIcon: false, hasBadge: true), 4)
        // icon, no badge (single-dir file) → 6.
        XCTAssertEqual(CompletionListLayout.textLeading(hasIcon: true, hasBadge: false), 6)
    }
}
