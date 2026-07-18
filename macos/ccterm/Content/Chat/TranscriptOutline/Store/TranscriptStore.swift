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

    /// Per-node layout cache, keyed by node id with the typeset width
    /// stored inside. A width mismatch is a miss that recomputes lazily —
    /// derived state, never authoritative.
    private var layoutCache: [UUID: (width: CGFloat, layout: RowLayout)] = [:]

    init(historySource: TranscriptHistoryService.Type) {
        self.historySource = historySource
    }

    // MARK: - Load

    func load(sessionId: String) {
        let messages = historySource.loadMessages(sessionId: sessionId)
        roots = TranscriptTreeBuilder.build(messages: messages).map(TranscriptNodeItem.init)
        layoutCache.removeAll()
    }

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

    /// The node's `RowLayout` at `width` (the cell's available content
    /// width). Cached; recomputed on a width change.
    func rowLayout(for item: TranscriptNodeItem, width: CGFloat) -> RowLayout {
        if let cached = layoutCache[item.id], cached.width == width {
            return cached.layout
        }
        let layout = Self.makeRowLayout(content: item.node.content, width: width)
        layoutCache[item.id] = (width, layout)
        return layout
    }

    /// Top / bottom padding contributed by the row around its layout.
    /// `top` drives the cell's `layoutOrigin.y`; `top + layout height +
    /// bottom` is the row height.
    func verticalPadding(for item: TranscriptNodeItem) -> (top: CGFloat, bottom: CGFloat) {
        Self.verticalPadding(for: item.node.content)
    }

    /// Total row height at `width` (padding + layout height).
    func height(for item: TranscriptNodeItem, width: CGFloat) -> CGFloat {
        let pad = verticalPadding(for: item)
        return pad.top + rowLayout(for: item, width: width).totalHeight + pad.bottom
    }

    // MARK: - Row-layout dispatch

    private static func makeRowLayout(
        content: TranscriptNode.Content, width: CGFloat
    ) -> RowLayout {
        switch content {
        case .block(let block):
            return makeBlockLayout(block, width: width)
        case .header(let title):
            // Inset by the same horizontal padding as `.block` / `.toolBody`
            // (the cell draws the title at `layoutOrigin.x =
            // blockHorizontalPadding`), so a long header title can't extend
            // past the content column into the right padding.
            let headerWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
            return .header(HeaderLayout.make(title: title, maxWidth: headerWidth))
        case .toolBody(let child):
            return .toolBody(ToolBodyLayout.make(child: child, rowWidth: width))
        }
    }

    /// Markdown / user block → `RowLayout`, rewritten from (not
    /// dependent on) the old `Transcript2Coordinator.makeLayout`,
    /// reusing only the pure per-kind `Layout` primitives (SPEC §7).
    /// `toolGroup` / `loadingPill` never reach here (the tree-ification
    /// never emits them); the defensive arm renders nothing.
    private static func makeBlockLayout(_ block: Block, width: CGFloat) -> RowLayout {
        let contentWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
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
        for content: TranscriptNode.Content
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch content {
        case .block(let block):
            return BlockStyle.blockPadding(for: block.kind)
        case .header:
            // Headers stack tightly; the native indent expresses the
            // hierarchy, so a small symmetric pad keeps the title band
            // from crowding its neighbours.
            return (top: 4, bottom: 4)
        case .toolBody:
            // A little breathing room under the header, more below so
            // the card doesn't butt against the next header.
            return (top: 2, bottom: 8)
        }
    }
}
