import AppKit

/// Owns the flat history transcript's state: it loads a session's history
/// through the injected `TranscriptHistoryService`, flattens it into
/// `[TranscriptRow]`, and caches each row's `RowLayout` per width. UI-free
/// — it holds no `NSView` and answers only data queries for the
/// controller's dataSource / delegate.
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

    /// id → row index, rebuilt on load. Lets a selection repaint resolve
    /// a row index from a row id without scanning.
    private var indexById: [UUID: Int] = [:]

    /// Per-row layout cache, keyed by row id with the typeset width stored
    /// inside. A width mismatch is a miss that recomputes lazily — derived
    /// state, never authoritative.
    private var layoutCache: [UUID: (width: CGFloat, layout: RowLayout)] = [:]

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
        layoutCache.removeAll()
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

    // MARK: - Layout

    /// The row's `RowLayout` at `width` — the **final typeset width**
    /// (already net of column padding; the controller computes it via
    /// `TranscriptMetrics.layoutWidth`, the single width chokepoint).
    /// Cached; recomputed on a width change.
    func rowLayout(for row: TranscriptRow, width: CGFloat) -> RowLayout {
        if let cached = layoutCache[row.id], cached.width == width {
            return cached.layout
        }
        let layout = Self.makeRowLayout(content: row.content, width: width)
        layoutCache[row.id] = (width, layout)
        return layout
    }

    /// The width a row's cached layout was typeset at, or `nil` if the row
    /// isn't cached. The post-resize refill (`TranscriptViewController`)
    /// uses this to find the off-screen rows whose cached width no longer
    /// matches the settled width — the ones the live-resize drag skipped.
    func cachedWidth(for id: UUID) -> CGFloat? {
        layoutCache[id]?.width
    }

    /// Recompute `requests` (row id + render content + target width) into
    /// the layout cache **off-main**, then land the entries on the main
    /// actor. Keeps a resize-end full recompute off the main thread so it
    /// never runs a CTLine pass inline. A write-back is dropped if a `load`
    /// happened during the compute (generation drift), so it can't poison a
    /// freshly-loaded session; within a session a wrong-width entry would
    /// just be a self-healing miss anyway.
    func refillLayouts(
        _ requests: [(id: UUID, content: TranscriptRow.Content, width: CGFloat)]
    ) async {
        guard !requests.isEmpty else { return }
        let gen = generation
        let computed = await Task.detached(priority: .userInitiated) {
            requests.map { req in
                (req.id, req.width, Self.makeRowLayout(content: req.content, width: req.width))
            }
        }.value
        guard gen == generation else { return }
        for (id, width, layout) in computed {
            layoutCache[id] = (width, layout)
        }
    }

    /// Top / bottom padding contributed by the row around its layout.
    /// `top` drives the cell's `layoutOrigin.y`; `top + layout height +
    /// bottom` is the row height.
    func verticalPadding(for row: TranscriptRow) -> (top: CGFloat, bottom: CGFloat) {
        switch row.content {
        case .block(let block): return BlockStyle.blockPadding(for: block.kind)
        case .groupHeader: return TranscriptMetrics.groupHeaderPadding
        }
    }

    /// Total row height at `width` (padding + layout height).
    func height(for row: TranscriptRow, width: CGFloat) -> CGFloat {
        let pad = verticalPadding(for: row)
        return pad.top + rowLayout(for: row, width: width).totalHeight + pad.bottom
    }

    // MARK: - Row-layout dispatch

    /// `width` is the final typeset width for every case — no further
    /// insetting here. Horizontal geometry has exactly one home
    /// (`TranscriptMetrics`); this function just forwards.
    ///
    /// `nonisolated` so `refillLayouts`' detached task can typeset off the
    /// main actor — the `Layout` primitives it calls (`HeaderLayout` / the
    /// block `Layout.make` family) are all pure and off-main-safe.
    nonisolated private static func makeRowLayout(
        content: TranscriptRow.Content, width: CGFloat
    ) -> RowLayout {
        switch content {
        case .block(let block):
            return makeBlockLayout(block, width: width)
        case .groupHeader(let title):
            return .header(HeaderLayout.make(title: title, maxWidth: width))
        }
    }

    /// Markdown / user block → `RowLayout`, reusing the pure per-kind
    /// `Layout` primitives. `toolGroup` / `loadingPill` never reach here
    /// (the flattening never emits them); the defensive arm renders nothing.
    nonisolated private static func makeBlockLayout(_ block: Block, width: CGFloat) -> RowLayout {
        let contentWidth = max(0, width)
        switch block.kind {
        case .heading(let level, let inlines):
            return .text(
                TextLayout.make(
                    attributed: BlockStyle.headingAttributed(level: level, inlines: inlines),
                    maxWidth: contentWidth))
        case .paragraph(let inlines):
            return .text(
                TextLayout.make(
                    attributed: BlockStyle.paragraphAttributed(inlines: inlines),
                    maxWidth: contentWidth))
        case .image(let image):
            return .image(
                ImageLayout.make(
                    image: image, maxWidth: contentWidth,
                    maxHeight: BlockStyle.imageMaxHeight))
        case .list(let listBlock):
            return .list(ListLayout.make(block: listBlock, maxWidth: contentWidth))
        case .table(let tableBlock):
            return .table(TableLayout.make(block: tableBlock, maxWidth: contentWidth))
        case .codeBlock(let language, let code):
            return .codeBlock(
                CodeBlockLayout.make(
                    code: code, language: language, tokens: nil,
                    copyButtonId: block.id, maxWidth: contentWidth))
        case .blockquote(let inlines):
            return .blockquote(BlockquoteLayout.make(inlines: inlines, maxWidth: contentWidth))
        case .thematicBreak:
            return .thematicBreak(ThematicBreakLayout.make(maxWidth: contentWidth))
        case .userBubble(let text, let isQueued):
            return .userBubble(
                UserBubbleLayout.make(text: text, isQueued: isQueued, maxWidth: contentWidth))
        case .userAttachments(let images):
            return .userAttachments(
                UserAttachmentsLayout.make(images: images, maxWidth: contentWidth))
        case .toolGroup, .loadingPill:
            return .text(.empty)
        }
    }
}
