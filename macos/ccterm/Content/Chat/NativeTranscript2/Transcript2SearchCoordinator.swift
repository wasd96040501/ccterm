import AppKit

/// In-transcript text search. Companion to `Transcript2SelectionCoordinator`
/// — same pattern (state lives here, owned by `Transcript2Coordinator`;
/// per-cell paint is derived; affected cells are reseated via
/// `markCellSearchDirty(blockId:)`). The two coordinators are independent:
/// search highlights compose over selection rather than replacing it.
///
/// ### Source of truth
///
/// `hits: [Hit]` is an ordered list across the whole transcript, sorted
/// by `(rowIndex, charOffset)`. `currentIndex` is the cursor — points at
/// the hit that's the "current" target for prev/next navigation. The
/// dict `hitsByBlock` is a derived lookup used by `viewFor` and
/// `markCellSearchDirty` to assemble per-cell paint state without
/// re-scanning the full hit list.
///
/// ### Search-range == selection-range
///
/// Each layout exposes `SelectionAdapter.searchableRegions` listing the
/// plain-text bands it is willing to expose to search. The scanner
/// walks those regions per block, runs a case-insensitive literal
/// `range(of:)` per region, and converts every match into a
/// `SelectionRange` via the region's `position` closure. The resulting
/// range is fed back into the *same* adapter's `rects` closure to draw
/// the highlight — so search hit rects are guaranteed visually
/// consistent with what a selection drag across the same chars would
/// produce.
///
/// ### Layout-agnostic
///
/// Like the selection coordinator, the scanner never `switch`es on
/// `LayoutPosition` cases — every conversion goes through the adapter.
/// Adding a new selectable layout that supplies `searchableRegions`
/// automatically gets search support; nothing in this file changes.
@MainActor
final class Transcript2SearchCoordinator: NSObject {
    weak var transcript: Transcript2Coordinator?

    /// One hit. `range` is in the layout's own opaque coordinate
    /// space; the cell projects it through the layout's adapter at
    /// draw time.
    struct Hit: Equatable, Sendable {
        let blockId: UUID
        let range: SelectionRange
    }

    private(set) var query: String = ""
    private(set) var hits: [Hit] = []
    private(set) var currentIndex: Int? = nil
    private var hitsByBlock: [UUID: [Int]] = [:]

    /// Fired after every state mutation so SwiftUI observers (search
    /// bar count / nav buttons) can react. Coordinator wires this
    /// through `Transcript2Controller`.
    var onStateChanged: (() -> Void)?

    // MARK: - Read

    var isActive: Bool { !query.isEmpty }
    var totalHits: Int { hits.count }

    /// Hits and the current-marker index restricted to one block.
    /// Returns `nil` when the block has no hits. `currentLocalIndex`
    /// is the position inside the returned array, or `nil` when the
    /// overall `currentIndex` doesn't land on this block.
    func hits(for blockId: UUID) -> (ranges: [SearchHighlightSpec], current: Int?)? {
        guard let indexes = hitsByBlock[blockId], !indexes.isEmpty else { return nil }
        var current: Int? = nil
        let specs = indexes.enumerated().map { (i, hitIdx) -> SearchHighlightSpec in
            if hitIdx == currentIndex { current = i }
            return SearchHighlightSpec(range: hits[hitIdx].range, isCurrent: hitIdx == currentIndex)
        }
        return (specs, current)
    }

    // MARK: - Mutation

    /// Drop the entry for a block whose row was removed / replaced.
    /// Called from `apply` alongside the selection / highlight drops.
    /// Hits for the dropped id are pruned and indexes after them
    /// shift down; if `currentIndex` pointed at one of them it
    /// rebases to the next surviving hit (or `nil` when no hits
    /// remain).
    func dropEntry(blockId: UUID) {
        guard hitsByBlock[blockId] != nil else { return }
        let prevCurrent = currentIndex.map { hits[$0] }
        hits.removeAll(where: { $0.blockId == blockId })
        rebuildHitIndex()
        if let prev = prevCurrent {
            currentIndex =
                hits.firstIndex(where: { $0 == prev })
                ?? (hits.isEmpty ? nil : 0)
        }
        onStateChanged?()
    }

    /// Re-run the scan against `query` over every block. Empty query
    /// clears state and dirties any previously highlighted cells.
    /// `query` is matched case-insensitively, literal (no regex).
    func runQuery(_ q: String) {
        let trimmed = q
        let prevQuery = query
        let prevHitBlocks = Set(hitsByBlock.keys)
        query = trimmed

        if trimmed.isEmpty {
            hits = []
            hitsByBlock = [:]
            currentIndex = nil
            // Dirty every block that previously carried hits so the
            // old yellow rects disappear on the next draw pass.
            for id in prevHitBlocks { transcript?.markCellSearchDirty(blockId: id) }
            onStateChanged?()
            return
        }

        let scanned = scan(query: trimmed)
        hits = scanned
        rebuildHitIndex()
        currentIndex = hits.isEmpty ? nil : 0
        // Repaint both the new hit set and any blocks that dropped
        // out (e.g. user typed an extra char and the old match
        // disappeared).
        let newHitBlocks = Set(hitsByBlock.keys)
        let dirty = prevHitBlocks.union(newHitBlocks)
        for id in dirty { transcript?.markCellSearchDirty(blockId: id) }
        // Same query as before with no behavior change is a no-op
        // for downstream observers — but we still let them know so
        // the search bar reflects the freshly-counted total (block
        // list may have changed between runs).
        _ = prevQuery
        onStateChanged?()
        navigateToCurrent()
    }

    /// Advance to the next hit, wrapping past the end. No-op when
    /// there are no hits.
    func next() {
        guard !hits.isEmpty else { return }
        let prev = currentIndex
        currentIndex = ((currentIndex ?? -1) + 1) % hits.count
        markCurrentTransitionDirty(prev: prev)
        onStateChanged?()
        navigateToCurrent()
    }

    /// Step back to the previous hit, wrapping past the start.
    func previous() {
        guard !hits.isEmpty else { return }
        let prev = currentIndex
        if let c = currentIndex {
            currentIndex = (c - 1 + hits.count) % hits.count
        } else {
            currentIndex = hits.count - 1
        }
        markCurrentTransitionDirty(prev: prev)
        onStateChanged?()
        navigateToCurrent()
    }

    /// Drop the entire search session. Repaints any cell that was
    /// carrying highlights.
    func clear() {
        runQuery("")
    }

    // MARK: - Scan

    /// Runs `O(N)` blocks doing string-only matching (no Core Text
    /// typeset), which clocks in at sub-ms even for 10k blocks — fine
    /// to keep on MainActor. Wrap in a detached task with a snapshot
    /// dict only if that ceases to hold.
    ///
    /// Returns hits in document order: outer loop walks blocks
    /// top-to-bottom, inner loop walks regions in the order the
    /// adapter exposes them, and per-region matches come back in
    /// ascending char order from `range(of:options:range:)`.
    private func scan(query: String) -> [Hit] {
        guard let tc = transcript, !query.isEmpty else { return [] }
        var out: [Hit] = []
        for id in tc.blockIds {
            guard let adapter = tc.selectionAdapter(forBlockId: id) else { continue }
            for region in adapter.searchableRegions() {
                Self.appendHits(
                    blockId: id, region: region,
                    query: query, into: &out)
            }
        }
        return out
    }

    nonisolated private static func appendHits(
        blockId: UUID,
        region: SearchableRegion,
        query: String,
        into out: inout [Hit]
    ) {
        let haystack = region.text as NSString
        guard haystack.length > 0 else { return }
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let found = haystack.range(
                of: query,
                options: [.caseInsensitive, .literal],
                range: searchRange)
            if found.location == NSNotFound { break }
            let start = region.position(found.location)
            let end = region.position(found.location + found.length)
            out.append(
                Hit(
                    blockId: blockId,
                    range: SelectionRange(start: start, end: end)))
            let next = found.location + max(1, found.length)
            if next >= haystack.length { break }
            searchRange = NSRange(
                location: next, length: haystack.length - next)
        }
    }

    // MARK: - Navigation

    /// Expand any folded ancestors of the current hit's row, scroll
    /// the row into view, and dirty the cell so the highlight
    /// repaints with the new `isCurrent` flag. No-op when no current
    /// hit.
    private func navigateToCurrent() {
        guard let idx = currentIndex, hits.indices.contains(idx),
            let tc = transcript
        else { return }
        let hit = hits[idx]
        // Pass the start position so a tool-group hit unfolds only the
        // specific child the highlight lives in; plain-text positions
        // get ignored by `expandForSearchHit`.
        tc.expandForSearchHit(blockId: hit.blockId, position: hit.range.start)
        tc.scrollBlockIntoView(blockId: hit.blockId)
        tc.markCellSearchDirty(blockId: hit.blockId)
    }

    /// On prev/next, dirty both the old and new current-hit's cell
    /// so the previous "active" tint flips back to inactive yellow
    /// and the new one picks up the active tint.
    private func markCurrentTransitionDirty(prev: Int?) {
        if let p = prev, hits.indices.contains(p) {
            transcript?.markCellSearchDirty(blockId: hits[p].blockId)
        }
        if let c = currentIndex, hits.indices.contains(c) {
            transcript?.markCellSearchDirty(blockId: hits[c].blockId)
        }
    }

    private func rebuildHitIndex() {
        hitsByBlock.removeAll(keepingCapacity: true)
        for (i, hit) in hits.enumerated() {
            hitsByBlock[hit.blockId, default: []].append(i)
        }
    }
}

/// Per-hit paint spec consumed by `BlockCellView`. `range` is the
/// opaque endpoint pair the cell projects through
/// `layout.selectionAdapter.rects`. `isCurrent` flips the fill from
/// the inactive yellow tint to the active (current-cursor) tint.
struct SearchHighlightSpec: Equatable, Sendable {
    let range: SelectionRange
    let isCurrent: Bool
}
