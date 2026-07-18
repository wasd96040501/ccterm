import AppKit

/// Owns the outline transcript's state: it loads a session's history
/// through the injected `TranscriptHistoryService`, tree-ifies it into
/// `TranscriptNode`s, wraps them in stable `TranscriptNodeItem` handles,
/// and caches each node's `RowLayout` per width. UI-free — it holds no
/// `NSView` and answers only data queries for the controller's
/// dataSource / delegate (SPEC §6.1).
///
/// One-shot blocking load: `load(sessionId:)` reads the whole history
/// synchronously (SPEC §2 — no paging backfill). Re-loading rebuilds the
/// tree and drops the layout cache.
@MainActor
final class TranscriptStore {
    /// Injected history reader (protocol metatype; production hands
    /// `SessionHistory.self`, tests a fake). Never a global / `.shared`.
    private let historySource: TranscriptHistoryService.Type

    /// Outline roots — the stable identity handles the controller hands
    /// to `NSOutlineView`.
    private(set) var roots: [TranscriptNodeItem] = []

    /// id → item over the whole tree, rebuilt on load. Lets the
    /// selection path resolve an item handle from a node id without
    /// walking the tree.
    private(set) var itemsById: [UUID: TranscriptNodeItem] = [:]

    /// Per-node layout cache, keyed by node id with the typeset width
    /// stored inside. A width mismatch is a miss that recomputes lazily —
    /// derived state, never authoritative.
    private var layoutCache: [UUID: (width: CGFloat, layout: RowLayout)] = [:]

    /// Bumped on every `load`. `refillLayouts`'s off-main compute captures
    /// it and discards its write-back if a reload happened meanwhile, so a
    /// resize refill that outlives a session switch can't poison the new
    /// session's cache with old-tree layouts.
    private var generation = 0

    init(historySource: TranscriptHistoryService.Type) {
        self.historySource = historySource
    }

    // MARK: - Load

    func load(sessionId: String) {
        let messages = historySource.loadMessages(sessionId: sessionId)
        roots = TranscriptTreeBuilder.build(messages: messages).map(TranscriptNodeItem.init)
        generation &+= 1
        layoutCache.removeAll()
        itemsById.removeAll()
        func index(_ items: [TranscriptNodeItem]) {
            for item in items {
                itemsById[item.id] = item
                index(item.children)
            }
        }
        index(roots)
    }

    func item(for id: UUID) -> TranscriptNodeItem? { itemsById[id] }

    // MARK: - Outline query surface

    /// Children of `item`, or the roots when `item` is `nil` (the outline
    /// asks for the root list with a `nil` item).
    func children(of item: TranscriptNodeItem?) -> [TranscriptNodeItem] {
        item?.children ?? roots
    }

    func numberOfChildren(of item: TranscriptNodeItem?) -> Int {
        children(of: item).count
    }

    func child(_ index: Int, of item: TranscriptNodeItem?) -> TranscriptNodeItem {
        children(of: item)[index]
    }

    func isExpandable(_ item: TranscriptNodeItem) -> Bool { item.isExpandable }

    // MARK: - Layout

    /// The node's `RowLayout` at `width` — the **final typeset width**
    /// (already net of column padding / indent / chevron slot; the
    /// controller computes it via `TranscriptOutlineMetrics.layoutWidth`,
    /// the single width chokepoint). Cached; recomputed on a width change.
    func rowLayout(for item: TranscriptNodeItem, width: CGFloat) -> RowLayout {
        if let cached = layoutCache[item.id], cached.width == width {
            return cached.layout
        }
        let layout = Self.makeRowLayout(content: item.node.content, width: width)
        layoutCache[item.id] = (width, layout)
        return layout
    }

    /// The width a node's cached layout was typeset at, or `nil` if the
    /// node isn't cached. The post-resize refill (`TranscriptViewController`)
    /// uses this to find the off-screen rows whose cached width no longer
    /// matches the settled width — the ones the live-resize drag phase
    /// skipped.
    func cachedWidth(for id: UUID) -> CGFloat? {
        layoutCache[id]?.width
    }

    /// Recompute `requests` (node id + render content + target width) into
    /// the layout cache **off-main**, then land the entries on the main
    /// actor — mirroring NativeTranscript2's `refillLayoutCache` off-main
    /// typeset (`makeRowLayout` is `nonisolated`; its `Layout` primitives
    /// are off-main-safe). Keeps a resize-end full recompute off the main
    /// thread so it never runs a CTLine pass inline. A write-back is
    /// dropped if a `load` happened during the compute (generation drift),
    /// so it can't poison a freshly-loaded session; within a session a
    /// wrong-width entry would just be a self-healing miss anyway.
    func refillLayouts(
        _ requests: [(id: UUID, content: TranscriptNode.Content, width: CGFloat)]
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
    /// bottom` is the row height. `level` distinguishes the group header
    /// (outline level 0) from tool headers (level 1) — same `Content`
    /// case, different L1/L2 rhythm tier.
    func verticalPadding(
        for item: TranscriptNodeItem, level: Int
    ) -> (top: CGFloat, bottom: CGFloat) {
        Self.verticalPadding(for: item.node.content, level: level)
    }

    /// Total row height at `width` (padding + layout height).
    func height(for item: TranscriptNodeItem, width: CGFloat, level: Int) -> CGFloat {
        let pad = verticalPadding(for: item, level: level)
        return pad.top + rowLayout(for: item, width: width).totalHeight + pad.bottom
    }

    // MARK: - Row-layout dispatch

    /// `width` is the final typeset width for every case — no further
    /// insetting here. Horizontal geometry has exactly one home
    /// (`TranscriptOutlineMetrics`); this function just forwards.
    ///
    /// `nonisolated` so `refillLayouts`' detached task can typeset off the
    /// main actor — the `Layout` primitives it calls (`HeaderLayout` /
    /// `ToolBodyLayout` / the block `Layout.make` family) are all pure and
    /// off-main-safe, same as the old renderer's `nonisolated makeLayout`.
    nonisolated private static func makeRowLayout(
        content: TranscriptNode.Content, width: CGFloat
    ) -> RowLayout {
        switch content {
        case .block(let block):
            return makeBlockLayout(block, width: width)
        case .header(let title):
            return .header(HeaderLayout.make(title: title, maxWidth: width))
        case .toolBody(let child):
            return .toolBody(ToolBodyLayout.make(child: child, maxWidth: width))
        }
    }

    /// Markdown / user block → `RowLayout`, rewritten from (not
    /// dependent on) the old `Transcript2Coordinator.makeLayout`,
    /// reusing only the pure per-kind `Layout` primitives (SPEC §7).
    /// `toolGroup` / `loadingPill` never reach here (the tree-ification
    /// never emits them); the defensive arm renders nothing.
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

    private static func verticalPadding(
        for content: TranscriptNode.Content, level: Int
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch content {
        case .block(let block):
            return BlockStyle.blockPadding(for: block.kind)
        case .header:
            // L1 (group header, level 0) vs L2 (tool header) — the strict
            // vertical rhythm lives in TranscriptOutlineMetrics.
            return level == 0
                ? TranscriptOutlineMetrics.groupHeaderPadding
                : TranscriptOutlineMetrics.toolHeaderPadding
        case .toolBody:
            return TranscriptOutlineMetrics.toolBodyPadding
        }
    }
}
