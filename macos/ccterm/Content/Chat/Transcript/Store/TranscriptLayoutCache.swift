import AppKit

/// Per-kind typeset cache for the flat history transcript.
///
/// Every block kind's measure is its own type (`TextLayout`,
/// `CodeBlockLayout`, `ListLayout`, …) — the Markdown component has no
/// shared layout type, by design — so this is **one dictionary per kind**
/// rather than one dictionary holding a type-erased value. Each entry
/// records the width it was typeset at: Core Text line breaking is a
/// function of width (`CTTypesetterSuggestLineBreak(_:_:width)`), so a
/// width mismatch is a miss that recomputes.
///
/// This is the transcript's performance floor. `heightOfRow`, `viewFor`
/// and every selection-drag tick read the *same* typeset, so scrolling
/// and dragging cost O(rows touched) instead of O(transcript) — and the
/// post-resize refill can precompute off-main and have the main thread
/// hit warm. Derived state: dropping any entry is always safe, the next
/// read recomputes it.
///
/// Holds no view: measures are plain values. The views that draw them
/// (`MarkdownParagraphView` and friends) are assembled in
/// `TranscriptViewController.viewFor`, the one place that knows the
/// view types.
@MainActor
final class TranscriptLayoutCache {
    private struct Entry<Measure> {
        let width: CGFloat
        let measure: Measure
    }

    // Paragraph and heading share the Core Text measure type — and the
    // dictionary, since a row is exactly one kind.
    private var text: [UUID: Entry<TextLayout>] = [:]
    private var codeBlock: [UUID: Entry<CodeBlockLayout>] = [:]
    private var list: [UUID: Entry<ListLayout>] = [:]
    private var table: [UUID: Entry<TableLayout>] = [:]
    private var blockquote: [UUID: Entry<BlockquoteLayout>] = [:]
    private var thematicBreak: [UUID: Entry<ThematicBreakLayout>] = [:]
    private var image: [UUID: Entry<ImageLayout>] = [:]
    private var userBubble: [UUID: Entry<UserBubbleLayout>] = [:]
    private var userAttachments: [UUID: Entry<UserAttachmentsLayout>] = [:]
    private var groupHeader: [UUID: Entry<TranscriptGroupHeaderLayout>] = [:]

    /// Row id → the width its cached entry was typeset at, across every
    /// kind. Lets a caller find the rows a width change left stale
    /// without knowing which kind each one is.
    private(set) var widths: [UUID: CGFloat] = [:]

    func removeAll() {
        text.removeAll()
        codeBlock.removeAll()
        list.removeAll()
        table.removeAll()
        blockquote.removeAll()
        thematicBreak.removeAll()
        image.removeAll()
        userBubble.removeAll()
        userAttachments.removeAll()
        groupHeader.removeAll()
        widths.removeAll()
    }

    // MARK: - Per-kind access (hit, or typeset and store)

    func paragraph(_ id: UUID, inlines: [InlineNode], width: CGFloat) -> TextLayout {
        if let entry = text[id], entry.width == width { return entry.measure }
        return store(Self.makeParagraph(inlines: inlines, width: width), id, width, in: &text)
    }

    func heading(
        _ id: UUID, level: Int, inlines: [InlineNode], width: CGFloat
    ) -> TextLayout {
        if let entry = text[id], entry.width == width { return entry.measure }
        return store(
            Self.makeHeading(level: level, inlines: inlines, width: width), id, width,
            in: &text)
    }

    func codeBlock(
        _ id: UUID, code: String, language: String?, width: CGFloat
    ) -> CodeBlockLayout {
        if let entry = codeBlock[id], entry.width == width { return entry.measure }
        return store(
            Self.makeCodeBlock(id: id, code: code, language: language, width: width),
            id, width, in: &codeBlock)
    }

    func list(_ id: UUID, block: ListBlock, width: CGFloat) -> ListLayout {
        if let entry = list[id], entry.width == width { return entry.measure }
        return store(Self.makeList(block: block, width: width), id, width, in: &list)
    }

    func table(_ id: UUID, block: TableBlock, width: CGFloat) -> TableLayout {
        if let entry = table[id], entry.width == width { return entry.measure }
        return store(Self.makeTable(block: block, width: width), id, width, in: &table)
    }

    func blockquote(
        _ id: UUID, inlines: [InlineNode], width: CGFloat
    ) -> BlockquoteLayout {
        if let entry = blockquote[id], entry.width == width { return entry.measure }
        return store(
            Self.makeBlockquote(inlines: inlines, width: width), id, width, in: &blockquote)
    }

    func thematicBreak(_ id: UUID, width: CGFloat) -> ThematicBreakLayout {
        if let entry = thematicBreak[id], entry.width == width { return entry.measure }
        return store(Self.makeThematicBreak(width: width), id, width, in: &thematicBreak)
    }

    func image(_ id: UUID, image source: NSImage, width: CGFloat) -> ImageLayout {
        if let entry = image[id], entry.width == width { return entry.measure }
        return store(Self.makeImage(source: source, width: width), id, width, in: &image)
    }

    func userBubble(
        _ id: UUID, text content: String, isQueued: Bool, width: CGFloat
    ) -> UserBubbleLayout {
        if let entry = userBubble[id], entry.width == width { return entry.measure }
        return store(
            Self.makeUserBubble(text: content, isQueued: isQueued, width: width),
            id, width, in: &userBubble)
    }

    func userAttachments(
        _ id: UUID, images: [NSImage], width: CGFloat
    ) -> UserAttachmentsLayout {
        if let entry = userAttachments[id], entry.width == width { return entry.measure }
        return store(
            Self.makeUserAttachments(images: images, width: width), id, width,
            in: &userAttachments)
    }

    func groupHeader(
        _ id: UUID, title: String, width: CGFloat
    ) -> TranscriptGroupHeaderLayout {
        if let entry = groupHeader[id], entry.width == width { return entry.measure }
        return store(
            Self.makeGroupHeader(title: title, width: width), id, width, in: &groupHeader)
    }

    /// Writes one freshly-typeset measure into its kind's dictionary and
    /// records the width. Split out of the accessors so the miss path
    /// reads the same everywhere; `inout` on a stored dictionary keeps
    /// the write exclusive to that one property.
    private func store<Measure>(
        _ measure: Measure, _ id: UUID, _ width: CGFloat,
        in storage: inout [UUID: Entry<Measure>]
    ) -> Measure {
        storage[id] = Entry(width: width, measure: measure)
        widths[id] = width
        return measure
    }

    // MARK: - Off-main batch

    /// Lands a batch typeset off the main actor. Same effect as having
    /// read each row through its accessor, minus the Core Text work.
    func apply(_ batch: Batch) {
        let width = batch.width
        for (id, measure) in batch.text { _ = store(measure, id, width, in: &text) }
        for (id, measure) in batch.codeBlock {
            _ = store(measure, id, width, in: &codeBlock)
        }
        for (id, measure) in batch.list { _ = store(measure, id, width, in: &list) }
        for (id, measure) in batch.table { _ = store(measure, id, width, in: &table) }
        for (id, measure) in batch.blockquote {
            _ = store(measure, id, width, in: &blockquote)
        }
        for (id, measure) in batch.thematicBreak {
            _ = store(measure, id, width, in: &thematicBreak)
        }
        for (id, measure) in batch.image { _ = store(measure, id, width, in: &image) }
        for (id, measure) in batch.userBubble {
            _ = store(measure, id, width, in: &userBubble)
        }
        for (id, measure) in batch.userAttachments {
            _ = store(measure, id, width, in: &userAttachments)
        }
        for (id, measure) in batch.groupHeader {
            _ = store(measure, id, width, in: &groupHeader)
        }
    }

    /// One off-main typeset pass over a set of rows at a single width.
    /// Grouped by kind for the same reason the cache is: the measures
    /// have no common type, so there is no single array to put them in.
    ///
    /// `@unchecked Sendable` mirrors the measures it carries — they hold
    /// immutable Core Text / CoreGraphics objects that are safe to hand
    /// across actors but aren't formally `Sendable`.
    struct Batch: @unchecked Sendable {
        let width: CGFloat
        var text: [(UUID, TextLayout)] = []
        var codeBlock: [(UUID, CodeBlockLayout)] = []
        var list: [(UUID, ListLayout)] = []
        var table: [(UUID, TableLayout)] = []
        var blockquote: [(UUID, BlockquoteLayout)] = []
        var thematicBreak: [(UUID, ThematicBreakLayout)] = []
        var image: [(UUID, ImageLayout)] = []
        var userBubble: [(UUID, UserBubbleLayout)] = []
        var userAttachments: [(UUID, UserAttachmentsLayout)] = []
        var groupHeader: [(UUID, TranscriptGroupHeaderLayout)] = []
    }

    /// Typeset `rows` at `width` without touching the cache — safe to
    /// call from a detached task, which is the point: a resize-end refill
    /// must not run a Core Text pass on the main thread.
    nonisolated static func makeBatch(rows: [TranscriptRow], width: CGFloat) -> Batch {
        var batch = Batch(width: width)
        for row in rows {
            switch row.content {
            case .groupHeader(let title):
                batch.groupHeader.append((row.id, makeGroupHeader(title: title, width: width)))
            case .block(let block):
                switch block.kind {
                case .paragraph(let inlines):
                    batch.text.append((row.id, makeParagraph(inlines: inlines, width: width)))
                case .heading(let level, let inlines):
                    batch.text.append(
                        (row.id, makeHeading(level: level, inlines: inlines, width: width)))
                case .codeBlock(let language, let code):
                    batch.codeBlock.append(
                        (
                            row.id,
                            makeCodeBlock(
                                id: block.id, code: code, language: language, width: width)
                        ))
                case .list(let listBlock):
                    batch.list.append((row.id, makeList(block: listBlock, width: width)))
                case .table(let tableBlock):
                    batch.table.append((row.id, makeTable(block: tableBlock, width: width)))
                case .blockquote(let inlines):
                    batch.blockquote.append(
                        (row.id, makeBlockquote(inlines: inlines, width: width)))
                case .thematicBreak:
                    batch.thematicBreak.append((row.id, makeThematicBreak(width: width)))
                case .image(let source):
                    batch.image.append((row.id, makeImage(source: source, width: width)))
                case .userBubble(let content, let isQueued):
                    batch.userBubble.append(
                        (
                            row.id,
                            makeUserBubble(text: content, isQueued: isQueued, width: width)
                        ))
                case .userAttachments(let images):
                    batch.userAttachments.append(
                        (row.id, makeUserAttachments(images: images, width: width)))
                }
            }
        }
        return batch
    }

    // MARK: - Typesetting
    //
    // The one place each kind's measure is produced. Both the accessors'
    // miss path and the off-main batch go through these, so a cached
    // measure and a refilled one can never diverge. All `nonisolated` —
    // the measures are pure functions of (content, width).

    nonisolated static func makeParagraph(
        inlines: [InlineNode], width: CGFloat
    ) -> TextLayout {
        TextLayout.make(
            attributed: BlockStyle.paragraphAttributed(inlines: inlines), maxWidth: width)
    }

    nonisolated static func makeHeading(
        level: Int, inlines: [InlineNode], width: CGFloat
    ) -> TextLayout {
        TextLayout.make(
            attributed: BlockStyle.headingAttributed(level: level, inlines: inlines),
            maxWidth: width)
    }

    /// `id` doubles as the copy button's identity, so per-button hover /
    /// flash feedback keys off the row that owns it.
    nonisolated static func makeCodeBlock(
        id: UUID, code: String, language: String?, width: CGFloat
    ) -> CodeBlockLayout {
        CodeBlockLayout.make(
            code: code, language: language, tokens: nil, copyButtonId: id, maxWidth: width)
    }

    nonisolated static func makeList(block: ListBlock, width: CGFloat) -> ListLayout {
        ListLayout.make(block: block, maxWidth: width)
    }

    nonisolated static func makeTable(block: TableBlock, width: CGFloat) -> TableLayout {
        TableLayout.make(block: block, maxWidth: width)
    }

    nonisolated static func makeBlockquote(
        inlines: [InlineNode], width: CGFloat
    ) -> BlockquoteLayout {
        BlockquoteLayout.make(inlines: inlines, maxWidth: width)
    }

    nonisolated static func makeThematicBreak(width: CGFloat) -> ThematicBreakLayout {
        ThematicBreakLayout.make(maxWidth: width)
    }

    nonisolated static func makeImage(source: NSImage, width: CGFloat) -> ImageLayout {
        ImageLayout.make(
            image: source, maxWidth: width, maxHeight: BlockStyle.imageMaxHeight)
    }

    nonisolated static func makeUserBubble(
        text: String, isQueued: Bool, width: CGFloat
    ) -> UserBubbleLayout {
        UserBubbleLayout.make(text: text, isQueued: isQueued, maxWidth: width)
    }

    nonisolated static func makeUserAttachments(
        images: [NSImage], width: CGFloat
    ) -> UserAttachmentsLayout {
        UserAttachmentsLayout.make(images: images, maxWidth: width)
    }

    nonisolated static func makeGroupHeader(
        title: String, width: CGFloat
    ) -> TranscriptGroupHeaderLayout {
        TranscriptGroupHeaderLayout.make(title: title, maxWidth: width)
    }
}
