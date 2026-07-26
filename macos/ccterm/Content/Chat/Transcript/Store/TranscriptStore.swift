import AppKit

/// Owns the flat history transcript's state: it loads a session's history
/// through the injected `TranscriptHistoryService`, flattens it into
/// `[TranscriptRow]`, and owns the per-row typeset cache. UI-free — it
/// holds no `NSView` and constructs none; measures are plain values, and
/// the views that draw them are assembled by the view controller.
///
/// One-shot blocking load: `load(sessionId:)` reads the whole history
/// synchronously (no paging backfill). Re-loading rebuilds the rows and
/// drops the layout cache.
@MainActor
final class TranscriptStore {
    /// Injected history reader (protocol metatype; production hands
    /// `SessionHistory.self`, tests a fake). Never a global / `.shared`.
    private let historySource: TranscriptHistoryService.Type

    /// The flat row list the controller hands to `NSTableView` by index.
    private(set) var rows: [TranscriptRow] = []

    /// Per-kind typeset cache, keyed by row id with the typeset width
    /// stored alongside. The view controller reads it directly in
    /// `viewFor` to hand each view its measure, so a row is typeset once
    /// and drawn, measured and selected from the same value.
    let layouts = TranscriptLayoutCache()

    /// id → row index, rebuilt on load. Lets a selection repaint resolve
    /// a row index from a row id without scanning.
    private var indexById: [UUID: Int] = [:]

    /// Bumped on every `load`. `refillLayouts`'s off-main compute captures
    /// it and discards its write-back if a reload happened meanwhile, so a
    /// resize refill that outlives a session switch can't poison the new
    /// session's cache with old-session layouts.
    private var generation = 0

    init(historySource: TranscriptHistoryService.Type) {
        self.historySource = historySource
    }

    // MARK: - Load

    func load(sessionId: String) {
        let messages = historySource.loadMessages(sessionId: sessionId)
        rows = TranscriptRowBuilder.build(messages: messages)
        generation &+= 1
        layouts.removeAll()
        indexById.removeAll()
        for (index, row) in rows.enumerated() { indexById[row.id] = index }
    }

    // MARK: - Row query surface

    var numberOfRows: Int { rows.count }

    func row(at index: Int) -> TranscriptRow? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    /// Row index hosting `id`, or `nil` if the id isn't present.
    func index(for id: UUID) -> Int? { indexById[id] }

    // MARK: - Measurement

    /// The row's height / measured width / selection geometry at `width`
    /// — the **final typeset width** (already net of column padding; the
    /// controller computes it via `TranscriptMetrics.layoutWidth`, the
    /// single width chokepoint).
    ///
    /// Reads through the layout cache, so this and the view that draws
    /// the row share one typeset. Which kind produced the numbers stays
    /// inside this switch: callers get the same three fields either way.
    func measurement(for row: TranscriptRow, width: CGFloat) -> TranscriptRowMeasurement {
        switch row.content {
        case .groupHeader(let title):
            let measure = layouts.groupHeader(row.id, title: title, width: width)
            return TranscriptRowMeasurement(
                height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                selectionAdapter: nil)
        case .block(let block):
            switch block.kind {
            case .paragraph(let inlines):
                let measure = layouts.paragraph(row.id, inlines: inlines, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .heading(let level, let inlines):
                let measure = layouts.heading(
                    row.id, level: level, inlines: inlines, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .codeBlock(let language, let code):
                let measure = layouts.codeBlock(
                    row.id, code: code, language: language, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .list(let listBlock):
                let measure = layouts.list(row.id, block: listBlock, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .table(let tableBlock):
                let measure = layouts.table(row.id, block: tableBlock, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .blockquote(let inlines):
                let measure = layouts.blockquote(row.id, inlines: inlines, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .thematicBreak:
                let measure = layouts.thematicBreak(row.id, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: nil)
            case .image(let source):
                let measure = layouts.image(row.id, image: source, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: nil)
            case .userBubble(let text, let isQueued):
                let measure = layouts.userBubble(
                    row.id, text: text, isQueued: isQueued, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: measure.selectionAdapter)
            case .userAttachments(let images):
                let measure = layouts.userAttachments(row.id, images: images, width: width)
                return TranscriptRowMeasurement(
                    height: measure.totalHeight, measuredWidth: measure.measuredWidth,
                    selectionAdapter: nil)
            }
        }
    }

    /// The width a row's cached typeset was produced at, or `nil` if the
    /// row isn't cached. The post-resize refill (`TranscriptViewController`)
    /// uses this to find the off-screen rows whose cached width no longer
    /// matches the settled width — the ones the live-resize drag skipped.
    func cachedWidth(for id: UUID) -> CGFloat? {
        layouts.widths[id]
    }

    /// Re-typeset `rows` at `width` **off-main**, then land the results in
    /// the cache on the main actor. Keeps a resize-end full recompute off
    /// the main thread so it never runs a Core Text pass inline. The
    /// write-back is dropped if a `load` happened during the compute
    /// (generation drift), so it can't poison a freshly-loaded session;
    /// within a session a wrong-width entry would just be a self-healing
    /// miss anyway.
    func refillLayouts(rows: [TranscriptRow], width: CGFloat) async {
        guard !rows.isEmpty else { return }
        let generationAtStart = generation
        let batch = await Task.detached(priority: .userInitiated) {
            TranscriptLayoutCache.makeBatch(rows: rows, width: width)
        }.value
        guard generationAtStart == generation else { return }
        layouts.apply(batch)
    }

    // MARK: - Row geometry

    /// Top / bottom padding contributed by the row around its content.
    /// `top` drives the view's `contentTopInset`; `top + content height +
    /// bottom` is the row height.
    func verticalPadding(for row: TranscriptRow) -> (top: CGFloat, bottom: CGFloat) {
        switch row.content {
        case .block(let block): return BlockStyle.blockPadding(for: block.kind)
        case .groupHeader: return TranscriptMetrics.groupHeaderPadding
        }
    }

    /// Total row height at `width` (padding + content height).
    func height(for row: TranscriptRow, width: CGFloat) -> CGFloat {
        let pad = verticalPadding(for: row)
        return pad.top + measurement(for: row, width: width).height + pad.bottom
    }
}
