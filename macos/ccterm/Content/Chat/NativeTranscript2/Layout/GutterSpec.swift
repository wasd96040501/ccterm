import Foundation

/// Cell-level decoration that floats in the margin **beside** a row's
/// layout content (outside the centered cell band). Each block declares
/// 0+ gutter specs via `Block.gutters`; the cell renders them in the
/// outer margin, hit-tests them, and reacts to clicks.
///
/// **Not part of the layout pipeline.** Gutters do not contribute to
/// `RowLayout.totalHeight`, do not enter `layoutCache`, and are not
/// computed off-main. The cell asks the layout for `firstLineCenterY`
/// to baseline-align the gutter glyph with the first line of content,
/// then derives the rect itself.
///
/// **Render-only state, no `Change.update`.** Click feedback (checkmark
/// flash) lives as cell-local transient state; the actual click action
/// is dispatched through `Transcript2Coordinator.handleGutter(_:on:)`,
/// which runs the heavy work (text serialization, pasteboard write)
/// off-main without touching the row's layout cache.
///
/// **Clipping policy.** Narrow windows have no spare margin — the cell
/// silently omits the gutter when the computed rect would overflow the
/// row bounds. No reservation, no width budget change, no layout
/// invalidation.
struct GutterSpec: Sendable, Equatable {
    let id: UUID
    let side: Side
    let kind: Kind

    enum Side: Sendable, Equatable {
        /// Left of the layout content. Used by every text-bearing block
        /// other than the right-aligned user bubble.
        case leading
        /// Right of the layout content. Used by the user bubble.
        case trailing
    }

    enum Kind: Sendable, Equatable {
        /// Copy the block's plain-text contents to the system pasteboard.
        /// Heavy serialization runs off the main thread (see
        /// `Block.copyableText`); the cell flashes a brief checkmark
        /// regardless of how the async copy resolves — opportunistic
        /// feedback, not transactional.
        case copy
    }
}
