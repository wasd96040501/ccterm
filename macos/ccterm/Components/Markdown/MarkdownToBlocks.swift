import Foundation

/// Converts markdown source (an assistant text segment) into NativeTranscript2's
/// `[Block]`. Reuses the project's existing `MarkdownDocument` parser; only
/// reshapes the IR: `MarkdownSegment` → `Block.Kind`, `MarkdownInline` →
/// `InlineNode`.
///
/// `idPrefix` derives stable UUIDs — within a single assistant entry, segment
/// order is fixed, so prefix + index folds into the same id every time and
/// the Coordinator's incremental diff stays on the fast path.
enum MarkdownToBlocks {
    static func blocks(source: String, idPrefix: String) -> [Block] {
        let doc = MarkdownDocument(parsing: source)
        var out: [Block] = []
        for (idx, seg) in doc.segments.enumerated() {
            appendSegment(seg, idPrefix: "\(idPrefix)|seg\(idx)", into: &out)
        }
        return out
    }

    // MARK: - Segment

    private static func appendSegment(
        _ seg: MarkdownSegment, idPrefix: String,
        into out: inout [Block]
    ) {
        switch seg {
        case .markdown(let blocks):
            for (i, b) in blocks.enumerated() {
                appendBlock(b, idPrefix: "\(idPrefix)|md\(i)", into: &out)
            }
        case .heading(let level, let inlines):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "heading"),
                    kind: .heading(level: level, inlines: convertInlines(inlines))))
        case .blockquote(let inner):
            let inlines = flattenToInlines(inner)
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "blockquote"),
                    kind: .blockquote(inlines: inlines)))
        case .list(let list):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "list"),
                    kind: .list(convertList(list))))
        case .codeBlock(let cb):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "code"),
                    kind: .codeBlock(language: cb.language, code: cb.code)))
        case .table(let tbl):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "table"),
                    kind: .table(convertTable(tbl))))
        case .mathBlock(let s):
            // NativeTranscript2 doesn't render math; fall back to a code-block
            // preview so the content at least survives.
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "math"),
                    kind: .codeBlock(language: "math", code: s)))
        case .thematicBreak:
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "hr"),
                    kind: .thematicBreak))
        }
    }

    private static func appendBlock(
        _ block: MarkdownBlock, idPrefix: String,
        into out: inout [Block]
    ) {
        switch block {
        case .paragraph(let inlines):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "para"),
                    kind: .paragraph(inlines: convertInlines(inlines))))
        case .heading(let level, let children):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "heading"),
                    kind: .heading(level: level, inlines: convertInlines(children))))
        case .blockquote(let inner):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "blockquote"),
                    kind: .blockquote(inlines: flattenToInlines(inner))))
        case .list(let list):
            out.append(
                Block(
                    id: StableBlockID.derive(idPrefix, "list"),
                    kind: .list(convertList(list))))
        }
    }

    // MARK: - Inline

    private static func convertInlines(_ nodes: [MarkdownInline]) -> [InlineNode] {
        nodes.compactMap(convertInline)
    }

    private static func convertInline(_ node: MarkdownInline) -> InlineNode? {
        switch node {
        case .text(let s):
            return .text(s)
        case .emphasis(let c):
            return .emphasis(convertInlines(c))
        case .strong(let c):
            return .strong(convertInlines(c))
        case .strikethrough(let c):
            return .strikethrough(convertInlines(c))
        case .code(let s):
            return .code(s)
        case .link(let dest, let children):
            let inner = convertInlines(children)
            if let url = URL(string: dest) {
                return .link(children: inner, url: url)
            }
            // Degrade to plain text to preserve readability.
            return inner.isEmpty ? .text(dest) : wrapText(inner)
        case .image(_, let alt):
            return .text("[image: \(alt)]")
        case .inlineMath(let s):
            return .code(s)
        case .lineBreak:
            return .lineBreak
        case .softBreak:
            // CommonMark: softbreak == space. Keep a single space and let the
            // wrap algorithm handle it naturally.
            return .text(" ")
        }
    }

    private static func wrapText(_ inlines: [InlineNode]) -> InlineNode {
        // Caller wants a single InlineNode. Wrapping in `strong` would lose
        // bold semantics; `emphasis` is similarly wrong. Flattening to a plain
        // text node is the only honest collapse.
        var s = ""
        for n in inlines {
            switch n {
            case .text(let t), .code(let t): s.append(t)
            case .strong(let c), .emphasis(let c), .strikethrough(let c):
                s.append(plainText(c))
            case .link(let c, _): s.append(plainText(c))
            case .lineBreak: s.append("\n")
            }
        }
        return .text(s)
    }

    private static func plainText(_ inlines: [InlineNode]) -> String {
        var s = ""
        for n in inlines {
            switch n {
            case .text(let t), .code(let t): s.append(t)
            case .strong(let c), .emphasis(let c), .strikethrough(let c):
                s.append(plainText(c))
            case .link(let c, _): s.append(plainText(c))
            case .lineBreak: s.append("\n")
            }
        }
        return s
    }

    // MARK: - List

    private static func convertList(_ list: MarkdownList) -> ListBlock {
        ListBlock(
            ordered: list.ordered,
            startIndex: list.startIndex ?? 1,
            items: list.items.map(convertListItem))
    }

    private static func convertListItem(_ item: MarkdownListItem) -> ListBlock.Item {
        let checkbox: Bool?
        switch item.checkbox {
        case .checked: checkbox = true
        case .unchecked: checkbox = false
        case nil: checkbox = nil
        }
        return ListBlock.Item(
            checkbox: checkbox,
            content: item.content.compactMap(convertListContent))
    }

    private static func convertListContent(_ block: MarkdownBlock) -> ListBlock.Content? {
        switch block {
        case .paragraph(let inlines):
            return .paragraph(convertInlines(inlines))
        case .heading(_, let children):
            return .paragraph(convertInlines(children))
        case .blockquote(let inner):
            return .paragraph(flattenToInlines(inner))
        case .list(let list):
            return .list(convertList(list))
        }
    }

    // MARK: - Table

    private static func convertTable(_ tbl: MarkdownTable) -> TableBlock {
        let alignments = tbl.alignments.map { a -> TableBlock.Alignment in
            switch a {
            case .none: return .none
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
        let header = tbl.header.map(convertInlines)
        let rows = tbl.rows.map { row in row.map(convertInlines) }
        return TableBlock(header: header, rows: rows, alignments: alignments)
    }

    // MARK: - Blockquote flattening

    /// `Block.blockquote` only carries `[InlineNode]` — no nested blocks. This
    /// folds a `MarkdownBlock` tree into a flat inline stream, inserting
    /// `lineBreak` between paragraphs.
    private static func flattenToInlines(_ blocks: [MarkdownBlock]) -> [InlineNode] {
        var out: [InlineNode] = []
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append(.lineBreak) }
            switch b {
            case .paragraph(let inlines), .heading(_, let inlines):
                out.append(contentsOf: convertInlines(inlines))
            case .blockquote(let inner):
                out.append(contentsOf: flattenToInlines(inner))
            case .list(let list):
                for (j, item) in list.items.enumerated() {
                    if j > 0 { out.append(.lineBreak) }
                    out.append(.text("• "))
                    out.append(contentsOf: flattenToInlines(item.content))
                }
            }
        }
        return out
    }
}
