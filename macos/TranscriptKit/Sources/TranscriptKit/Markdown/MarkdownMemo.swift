import AppKit

/// What one row's document cost to build last time, so that the next version of
/// it — a token longer — pays only for the parts that actually changed.
///
/// A streaming row hands over its **whole** text on every frame, because that is
/// the only thing a data source can be asked for and the only thing markdown can
/// be parsed from: appending three characters can turn the preceding six lines
/// into a code block, so there is no such thing as rendering a suffix. This is
/// what makes re-reading the whole document affordable anyway.
///
/// ## Three costs, and which one this is about
///
/// Re-rendering a document that grew by a token costs, in ascending order:
///
/// - **Parsing.** cmark over the whole source. It has no incremental entry point
///   — no member of that family does — so this is paid in full every frame, and
///   is the cheapest of the three by an order of magnitude.
/// - **Shaping and typesetting.** Building each block's `NSAttributedString` and
///   running Core Text over it. This is the expensive one, and the one this type
///   exists to skip.
///
/// **That ordering is about a frame of streaming, and it does not hold for a
/// width change**, which is worth saying here because reading it as universal
/// cost the transcript a visible freeze. When only the width moved, shaping is
/// reused — that is what keeping the recipe buys — so parsing is not the cheapest
/// item left, it is the *largest*: measured over 183 real documents, re-laying a
/// document out at a new width is 60% parse, 32% line-breaking, 2% looking the
/// children up. And every one of those parses is provably redundant, since the
/// source has not moved a character. `remeasure(width:)` is that path, and the
/// parse does not happen on it at all.
/// - **Repainting.** The row's surfaces redraw whole, because `BlockView`
///   invalidates whole. Untouched, and the next thing to look at if streaming a
///   very long message is still not free.
///
/// ## Why this is a memo and not a diff
///
/// There is no edit script here and no block identity. Every `MarkdownIR` value
/// is `Hashable`, and `BlockStack` assigns origins and index bases at stacking
/// time — so a child that did not change can be looked up **by value** and
/// dropped back into the document wherever it now lands. A paragraph inserted in
/// the middle costs that paragraph, not everything after it.
///
/// This is also why the renderer this replaces needed a stable-id scheme
/// (`StableBlockID`, hashing a coordinate into a UUID) and this does not: there,
/// a block *was* a table row, and a row needs identity before it can be diffed.
/// Here a block is inside one row, so value equality is the whole mechanism.
///
/// ## Generations
///
/// Each call reads the previous generation and writes a new one holding exactly
/// the children the document has now, so nothing needs evicting and the memory
/// is one document's worth. The only realistic donor is this same row's previous
/// frame, which is why the store is per-row (`RowCache`) rather than shared.
struct MarkdownMemo {

    /// One child, and what it cost.
    private struct Entry {

        /// Width-independent — shaped, not yet broken into lines. Survives a
        /// resize, which is what keeps a width change re-typesetting rather than
        /// rebuilding.
        let block: Block

        let measured: MeasuredBlock

        /// The width `measured` was measured into.
        let width: CGFloat
    }

    private var entries: [MarkdownBlockBuilder.Child: Entry] = [:]

    /// The children of the document this memo last measured, in the order they
    /// appear in it.
    ///
    /// **Why a dictionary alone is not enough.** `entries` answers "what did this
    /// child cost", which is everything a *stream* needs — the order comes free
    /// with the re-parse a new version requires anyway. A width change has no new
    /// version and therefore no parse, and without one there is nothing to say
    /// which child comes first: `BlockStack` stacks an array. So the parse was
    /// being run, on unchanged source, purely to remember the running order.
    ///
    /// Holding the children themselves rather than positions is what makes
    /// `remeasure(width:)` total: a child *is* the recipe's ingredients, so even a
    /// slot the dictionary has somehow lost can be rebuilt without the source. And
    /// duplicates stay shared — a child appearing twice appears twice here and
    /// resolves to one entry both times, exactly as during a `measure`.
    ///
    /// `MarkdownIR` values are copy-on-write, so this is one retain per top-level
    /// block rather than a second copy of the document.
    private var order: [MarkdownBlockBuilder.Child] = []

    /// `source`, parsed and laid out at `width`, with **nothing** to take from —
    /// a document arriving whole rather than growing into place.
    ///
    /// Written as an empty memo rather than as a call to `MarkdownBlockBuilder`
    /// so that "measured cold" and "measured after a stream" are one code path
    /// with a different starting state, instead of two expressions that have to
    /// be kept agreeing. `TranscriptRowContent.measured(width:)` is the caller,
    /// and `TranscriptView.prepareRows(_:)` reaches it from a background task —
    /// which is sound for the reason on `Block`: none of this touches
    /// main-thread state, and the generation it allocates is discarded here.
    /// The memo comes back with the measurement rather than being discarded: it
    /// is the donor the *next* version of this document will take from, and a
    /// caller that threw it away would be handing the cache an answer with no
    /// past — see `RowCache.Body`'s note on the case that used to represent that.
    static func measured(
        _ source: String, width: CGFloat, style: MarkdownStyle = .default
    ) -> (memo: MarkdownMemo, measured: MeasuredBlock) {
        var memo = MarkdownMemo()
        let measured = memo.measure(source, width: width, style: style)
        return (memo, measured)
    }

    /// `source`, parsed and laid out at `width`, taking whatever the previous
    /// call left behind.
    mutating func measure(
        _ source: String, width: CGFloat, style: MarkdownStyle = .default
    ) -> MeasuredBlock {
        let children = MarkdownBlockBuilder.children(of: MarkdownParser.document(source))

        var next = [MarkdownBlockBuilder.Child: Entry](minimumCapacity: children.count)
        var measured: [MeasuredBlock] = []
        measured.reserveCapacity(children.count)

        for child in children {
            // `next` first: two identical paragraphs in one document are one
            // entry, and sharing a measured value between them is correct for the
            // same reason reuse across frames is — a measured block carries no
            // position.
            let entry = next[child] ?? resolve(child, width: width, style: style)
            next[child] = entry
            measured.append(entry.measured)
        }

        entries = next
        order = children
        return BlockStack.stack(
            measured, spacing: MarkdownBlockBuilder.blockSpacing, width: width)
    }

    /// The **same document** laid out at a different width, taking every recipe
    /// this memo already holds.
    ///
    /// No source, and therefore no parse: the children are already known, and a
    /// width change cannot alter which ones there are. `resolve` is the same one
    /// `measure(_:width:style:)` uses, entered on the branch where the recipe is
    /// kept and only the lines are broken again — so this is not a second way of
    /// laying a document out, it is the first way with the parse removed from in
    /// front of it.
    ///
    /// The caller is `RowCache`, on the one occasion it can prove the source did
    /// not move: it compares content before it decides which of these two to call.
    /// Getting *that* comparison wrong is what this path can be broken by, and it
    /// shows up as a row rendering an older version of itself —
    /// `MarkdownGrowthTests.testAWidthChangeBetweenGrowthsDoesNotServeAStaleParse`
    /// is the guard.
    ///
    /// A memo that has never measured anything answers with an empty stack rather
    /// than refusing, which is the same thing `measure` does with an empty
    /// document and needs no case of its own.
    mutating func remeasure(width: CGFloat, style: MarkdownStyle = .default) -> MeasuredBlock {
        var next = [MarkdownBlockBuilder.Child: Entry](minimumCapacity: order.count)
        var measured: [MeasuredBlock] = []
        measured.reserveCapacity(order.count)

        for child in order {
            let entry = next[child] ?? resolve(child, width: width, style: style)
            next[child] = entry
            measured.append(entry.measured)
        }

        entries = next
        return BlockStack.stack(
            measured, spacing: MarkdownBlockBuilder.blockSpacing, width: width)
    }

    /// The entry for `child` at `width`: reused whole, re-measured from a reused
    /// recipe, or built from nothing — in decreasing order of how often it
    /// happens while a message streams.
    private func resolve(
        _ child: MarkdownBlockBuilder.Child, width: CGFloat, style: MarkdownStyle
    ) -> Entry {
        guard let hit = entries[child] else {
            let block = MarkdownBlockBuilder.make(child, style: style)
            return Entry(block: block, measured: block.measure(width), width: width)
        }
        guard hit.width != width else { return hit }
        return Entry(block: hit.block, measured: hit.block.measure(width), width: width)
    }
}
