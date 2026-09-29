import CoreGraphics

/// A resolved anchor: what one commit holds still (SPEC §6).
///
/// It lives only from resolving to restoring, inside one commit. The list keeps
/// no anchor between commits, and tail following is decided by position alone
/// (A8).
public enum ScrollAnchor: Equatable, Sendable {

    /// Restore to `oMax` (A6).
    case tail

    /// Row `row` is `distance` below the top of `U`, so `y(row) − (o + t)`.
    /// The distance is ≤ 0 when the row starts above the viewport.
    case row(Int, distance: CGFloat)

    /// Restore to this offset (A3, A9).
    case offset(CGFloat)

    /// A1–A3: resolves a policy against the geometry before the batch.
    /// `followsTail` is `automaticallyFollowsTail`; whether the viewport is at
    /// the tail is worked out here.
    public static func resolve(
        _ anchoring: Anchoring, heights: RowHeights, viewport: Viewport, followsTail: Bool
    ) -> ScrollAnchor {
        switch anchoring {
        case .automatic:
            if followsTail, viewport.isAtTail(contentHeight: heights.contentHeight) {
                return .tail
            }
            guard let first = heights.firstRow(endingBelow: viewport.unobscuredTop) else {
                return .offset(viewport.offset)
            }
            return .row(first, distance: heights.top(ofRow: first) - viewport.unobscuredTop)
        case .row(let row):
            precondition(
                row >= 0 && row < heights.count,
                "ExactList: anchoring row \(row) out of range 0..<\(heights.count) (L12)")
            return .row(row, distance: heights.top(ofRow: row) - viewport.unobscuredTop)
        case .scrollOffset:
            return .offset(viewport.offset)
        }
    }

    /// A4, A5: carries a row anchor through the batch. If the anchor row was
    /// removed, the anchor passes to a survivor, which keeps its own pre-batch
    /// screen position; that is why the old heights and viewport are needed.
    public func mapped(
        through map: RowIndexMap, oldHeights: RowHeights, oldViewport: Viewport
    ) -> ScrollAnchor {
        guard case .row(let row, let distance) = self else { return self }
        if let moved = map.newIndex(forOld: row) {
            return .row(moved, distance: distance)
        }
        let survivor =
            (row + 1..<map.oldCount).first { map.newIndex(forOld: $0) != nil }
            ?? (0..<row).reversed().first { map.newIndex(forOld: $0) != nil }
        guard let survivor, let index = map.newIndex(forOld: survivor) else {
            return .offset(oldViewport.minOffset)
        }
        return .row(index, distance: oldHeights.top(ofRow: survivor) - oldViewport.unobscuredTop)
    }

    /// W2: rescales a row anchor's distance by the row's new height over its
    /// old one. Other anchors are returned unchanged.
    public func rescaled(fromHeight old: CGFloat, toHeight new: CGFloat) -> ScrollAnchor {
        guard case .row(let row, let distance) = self else { return self }
        return .row(row, distance: distance * new / old)
    }

    /// A6, A7: the offset that restores this anchor against the new geometry,
    /// clamped to the new scroll range.
    public func restoredOffset(heights: RowHeights, viewport: Viewport) -> CGFloat {
        let contentHeight = heights.contentHeight
        switch self {
        case .tail:
            return viewport.maxOffset(contentHeight: contentHeight)
        case .row(let row, let distance):
            let offset = heights.top(ofRow: row) - viewport.insetTop - distance
            return viewport.clamped(offset, contentHeight: contentHeight)
        case .offset(let offset):
            return viewport.clamped(offset, contentHeight: contentHeight)
        }
    }
}
