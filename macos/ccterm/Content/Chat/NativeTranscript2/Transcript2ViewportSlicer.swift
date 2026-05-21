import AppKit

/// Pure function that decides which contiguous slice of `blocks` covers
/// the viewport given a starting anchor and the viewport's height.
///
/// **Why it's a separate type, not a method on Coordinator or Controller:**
/// the same slicing logic is consumed by two unrelated entry points —
/// `Transcript2Controller.setHistory` (first load: new blocks arriving)
/// and `Transcript2Coordinator.materializeFirstAppear` (reentry: blocks
/// already populated, AppKit just hasn't seen them). Each entry point
/// runs at a different lifecycle moment and against a different
/// `blocks` source. Keeping the slicer here, parameterized by data
/// only, makes it freely composable: both callers compute their slice
/// from the same primitive and then hand it off to their own
/// downstream phased-rollout machinery.
///
/// **Why `nonisolated static`:** the slicer is a pure function of its
/// inputs. The `Transcript2Coordinator.makeLayout`-based height
/// computation it ultimately calls is already `nonisolated static` (per
/// the NativeTranscript2 perf contract §2.5), so the slicer inherits
/// that property — it can run from any actor context, on a detached
/// task, or in the main hop.
///
/// **Why an injectable `rowHeight` closure:** the realistic caller plugs
/// in `Transcript2Coordinator.makeLayout`-based height computation,
/// which depends on Core Text font metrics and isn't deterministic
/// across font-version updates or system-font swaps. Tests inject a
/// deterministic stub (e.g. "every block is 20pt tall") so they can
/// assert exact slice boundaries against a fixture without coupling to
/// real layout output. Production code goes through `slice(blocks:
/// anchor: width: viewportHeight:)`, which wraps the closure-form with
/// the production height function.
enum Transcript2ViewportSlicer {

    /// Computes the contiguous range of `blocks` that just covers the
    /// viewport from the requested anchor.
    ///
    /// **Walking semantics:**
    /// - `.bottom` — walks from the END of `blocks` backward, summing
    ///   row heights until they ≥ `viewportHeight`. Returns
    ///   `firstCoveringIndex..<blocks.count`.
    /// - `.top(id)` — walks forward from the block with `id`, summing
    ///   until coverage. Returns `id.idx..<lastCoveringIndex + 1`.
    /// - `.bottomTo(id)` — walks backward from the block with `id`,
    ///   summing until coverage. Returns
    ///   `firstCoveringIndex..<id.idx + 1`.
    /// - Unknown `id` (the block was removed) — fallback to `.bottom`'s
    ///   logic; same posture as `Coordinator`'s `.insert(after: id)`
    ///   handling of stale anchors.
    ///
    /// **Edge cases:**
    /// - `blocks.isEmpty` → empty range `0..<0`.
    /// - Even one block exceeds `viewportHeight` → slice includes that
    ///   one block only (overshoots viewport rather than undershoots,
    ///   matching the "viewport-cover" contract).
    /// - All blocks combined are shorter than `viewportHeight` → full
    ///   range `0..<blocks.count`.
    nonisolated static func slice(
        blocks: [Block],
        anchor: Transcript2Controller.InitialAnchor,
        viewportHeight: CGFloat,
        rowHeight: (Block) -> CGFloat
    ) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        guard viewportHeight > 0 else {
            // No viewport to cover: degenerate to "anchor block only" so
            // callers (Phase 1) still have a non-empty starting slice
            // even before the viewport tiles. The full set lands in
            // Phase 2 either way.
            switch anchor {
            case .bottom:
                return (blocks.count - 1)..<blocks.count
            case .top(let id):
                let idx = blocks.firstIndex(where: { $0.id == id }) ?? 0
                return idx..<(idx + 1)
            case .bottomTo(let id):
                let idx =
                    blocks.firstIndex(where: { $0.id == id })
                    ?? (blocks.count - 1)
                return idx..<(idx + 1)
            }
        }

        switch anchor {
        case .bottom:
            return sliceWalkingBackward(
                from: blocks.count - 1, in: blocks,
                viewportHeight: viewportHeight, rowHeight: rowHeight,
                endInclusive: blocks.count - 1)

        case .top(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id })
            else {
                return slice(
                    blocks: blocks, anchor: .bottom,
                    viewportHeight: viewportHeight, rowHeight: rowHeight)
            }
            return sliceWalkingForward(
                from: anchorIdx, in: blocks,
                viewportHeight: viewportHeight, rowHeight: rowHeight)

        case .bottomTo(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id })
            else {
                return slice(
                    blocks: blocks, anchor: .bottom,
                    viewportHeight: viewportHeight, rowHeight: rowHeight)
            }
            return sliceWalkingBackward(
                from: anchorIdx, in: blocks,
                viewportHeight: viewportHeight, rowHeight: rowHeight,
                endInclusive: anchorIdx)
        }
    }

    /// Production overload: `rowHeight` is computed via
    /// `Transcript2Coordinator.makeLayout` at the supplied `width`,
    /// matching exactly what `heightOfRow` would return at that width.
    /// Folds and statuses are intentionally NOT threaded in here — the
    /// viewport slice is an attach-time geometry probe, where no
    /// user-folds have been applied yet and statuses haven't shifted
    /// row heights (they only repaint colors per perf contract §2.13).
    /// Using the default-folds / default-statuses path keeps the
    /// slice deterministic across the bridge's mid-attach status
    /// flips.
    nonisolated static func slice(
        blocks: [Block],
        anchor: Transcript2Controller.InitialAnchor,
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> Range<Int> {
        slice(
            blocks: blocks, anchor: anchor,
            viewportHeight: viewportHeight
        ) { block in
            let pad = BlockStyle.blockPadding(for: block.kind)
            return Transcript2Coordinator.makeLayout(
                for: block, width: width
            ).totalHeight + pad.top + pad.bottom
        }
    }

    // MARK: - Walking helpers

    /// Walks forward from `start`, accumulating row heights, until
    /// coverage reaches `viewportHeight`. Returns the half-open range
    /// `start..<(last + 1)` where `last` is the final index visited.
    nonisolated private static func sliceWalkingForward(
        from start: Int,
        in blocks: [Block],
        viewportHeight: CGFloat,
        rowHeight: (Block) -> CGFloat
    ) -> Range<Int> {
        var height: CGFloat = 0
        var last = start
        for i in start..<blocks.count {
            height += rowHeight(blocks[i])
            last = i
            if height >= viewportHeight { break }
        }
        return start..<(last + 1)
    }

    /// Walks backward from `start`, accumulating row heights, until
    /// coverage reaches `viewportHeight`. Returns the half-open range
    /// `first..<(endInclusive + 1)` where `first` is the final index
    /// visited.
    nonisolated private static func sliceWalkingBackward(
        from start: Int,
        in blocks: [Block],
        viewportHeight: CGFloat,
        rowHeight: (Block) -> CGFloat,
        endInclusive end: Int
    ) -> Range<Int> {
        var height: CGFloat = 0
        var first = start
        for i in stride(from: start, through: 0, by: -1) {
            height += rowHeight(blocks[i])
            first = i
            if height >= viewportHeight { break }
        }
        return first..<(end + 1)
    }
}
