import CoreGraphics

/// Pure-math layout constants + height computation for the completion popup
/// (migration plan §4.3). Carries NO AppKit view dependency so it is the
/// directly-testable surface (`CompletionListLayoutTests`, a CI gate): the
/// constants + `listHeight(...)` + `displayCount(...)` are lifted verbatim
/// from the deleted `CompletionListView.swift` (lines 8-19, 216-227) so the
/// AppKit popup is pixel-exact against the old SwiftUI list.
///
/// The four render branches (B1-B4, §4.3-2) are fully determined by
/// `(headerPresent, itemCount, isLoading, hasSelectedDetail)`:
///   B1  header + empty           → header-only, no placeholder  → 32
///   B2  no header + empty + load → single Loading row           → 32
///   B3  no header + empty + !load→ single empty row             → 32
///   B4  items non-empty          → opt header + ≤10 rows + detail
struct CompletionListLayout {

    // MARK: - Constants (verbatim from CompletionListView.swift:8-14)

    /// Every header / empty / command-line row is exactly this tall.
    /// (`CompletionListView.swift:8`)
    static let rowHeight: CGFloat = 24
    /// Top + bottom breathing room; `listHeight` adds `2 * verticalInset`.
    /// (`CompletionListView.swift:9`)
    static let verticalInset: CGFloat = 4
    /// Items beyond this scroll; `displayCount` clamps to `min(count, 10)`.
    /// (`CompletionListView.swift:10`)
    static let maxVisibleItems = 10
    /// One line of the in-row selected-row description.
    /// (`CompletionListView.swift:12`)
    static let detailLineHeight: CGFloat = 15
    /// Breathing room under the in-row description.
    /// (`CompletionListView.swift:14`)
    static let detailBottomPadding: CGFloat = 6

    /// Height a selected row gains to host its (up to two-line) description.
    /// Reserved at EXACTLY two lines (`detailLineHeight * 2 + detailBottomPadding`
    /// = 15*2+6 = 36) so moving between two described commands never resizes
    /// the popup. (`CompletionListView.swift:19`)
    static let detailBlockHeight: CGFloat = detailLineHeight * 2 + detailBottomPadding

    // MARK: - displayCount (verbatim from CompletionListView.swift:216-220)

    /// The number of CONTENT rows the list draws (header is separate). Mirrors
    /// `CompletionListView.displayCount`:
    ///   - header present && items empty → 0 (header-only, no placeholder)
    ///   - items empty (loading or not)  → 1 (a single empty/loading row)
    ///   - items non-empty               → `min(count, maxVisibleItems)`
    ///
    /// `isLoading` does not change the COUNT (it's still one empty row); it
    /// only selects which empty-state view renders. It is kept in the
    /// signature to mirror the original branch shape 1:1.
    static func displayCount(headerPresent: Bool, itemCount: Int, isLoading: Bool) -> Int {
        if headerPresent && itemCount == 0 { return 0 }
        if isLoading && itemCount == 0 { return 1 }
        return itemCount == 0 ? 1 : min(itemCount, maxVisibleItems)
    }

    // MARK: - listHeight (verbatim from CompletionListView.swift:222-227)

    /// The popup's fixed pixel height for a given state. Mirrors
    /// `CompletionListView.listHeight`:
    /// `headerH + contentH + detailH + 2 * verticalInset`, where
    ///   headerH  = headerPresent ? rowHeight : 0
    ///   contentH = displayCount * rowHeight
    ///   detailH  = hasSelectedDetail ? detailBlockHeight : 0
    static func listHeight(
        headerPresent: Bool,
        displayCount: Int,
        hasSelectedDetail: Bool
    ) -> CGFloat {
        let headerH: CGFloat = headerPresent ? rowHeight : 0
        let contentH = CGFloat(displayCount) * rowHeight
        let detailH: CGFloat = hasSelectedDetail ? detailBlockHeight : 0
        return headerH + contentH + detailH + 2 * verticalInset
    }

    // MARK: - Description folding (verbatim from CompletionListView.swift:200-205)

    /// Cleaned description for a raw `displayDetail`, or nil when it folds to
    /// empty. Trims + folds every whitespace run (incl. `\n` `\t`) into one
    /// space — only slash commands populate `displayDetail`, so the in-row
    /// description is effectively slash-only.
    static func cleanedDetail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The selected row's cleaned description (drives `detailH`), or nil when
    /// the index is out of range or the item carries no description.
    /// (verbatim from `CompletionListView.swift:207-212`)
    static func selectedDetail(items: [any CompletionItem], selectedIndex: Int) -> String? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return cleanedDetail(items[selectedIndex].displayDetail)
    }

    // MARK: - textLeading (verbatim from CompletionListView.swift:190-193)

    /// Leading inset for a row's primary text. Icon-bearing rows sit after the
    /// 16pt glyph; text-only rows (slash commands) take the icon's own 13pt
    /// leading so the column edge stays aligned.
    static func textLeading(hasIcon: Bool, hasBadge: Bool) -> CGFloat {
        if !hasIcon && !hasBadge { return 13 }
        return hasBadge ? 4 : 6
    }
}
