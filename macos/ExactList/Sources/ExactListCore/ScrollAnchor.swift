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
        fatalError("unimplemented: SPEC A1–A3")
    }

    /// A4, A5: carries a row anchor through the batch. If the anchor row was
    /// removed, the anchor passes to a survivor, which keeps its own pre-batch
    /// screen position; that is why the old heights and viewport are needed.
    public func mapped(
        through map: RowIndexMap, oldHeights: RowHeights, oldViewport: Viewport
    ) -> ScrollAnchor {
        fatalError("unimplemented: SPEC A4, A5")
    }

    /// W2: rescales a row anchor's distance by the row's new height over its
    /// old one. Other anchors are returned unchanged.
    public func rescaled(fromHeight old: CGFloat, toHeight new: CGFloat) -> ScrollAnchor {
        fatalError("unimplemented: SPEC W2")
    }

    /// A6, A7: the offset that restores this anchor against the new geometry,
    /// clamped to the new scroll range.
    public func restoredOffset(heights: RowHeights, viewport: Viewport) -> CGFloat {
        fatalError("unimplemented: SPEC A6, A7")
    }
}
