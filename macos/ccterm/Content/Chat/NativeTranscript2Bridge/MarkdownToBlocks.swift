import Foundation

/// 把 markdown 源文本(assistant text segment)转成 NativeTranscript2 的
/// `[Block]`。复用项目已有的 `MarkdownDocument` parser,只做 IR 形态变换:
/// `MarkdownSegment` → `Block.Kind`、`MarkdownInline` → `InlineNode`。
///
/// `idPrefix` 用来派生稳定 UUID — 同一个 assistant entry 内,segment 顺序
/// 不变,前缀 + index 折出的 id 也不会变,Coordinator 的增量 diff 走快路径。
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

    private static func appendSegment(_ seg: MarkdownSegment, idPrefix: String,
                                      into out: inout [Block]) {
        switch seg {
        case .markdown(let blocks):
            for (i, b) in blocks.enumerated() {
                appendBlock(b, idPrefix: "\(idPrefix)|md\(i)", into: &out)
            }
        case .heading(let level, let inlines):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "heading"),
                kind: .heading(level: level, inlines: convertInlines(inlines))))
        case .blockquote(let inner):
            let inlines = flattenToInlines(inner)
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "blockquote"),
                kind: .blockquote(inlines: inlines)))
        case .list(let list):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "list"),
                kind: .list(convertList(list))))
        case .codeBlock(let cb):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "code"),
                kind: .codeBlock(language: cb.language, code: cb.code)))
        case .table(let tbl):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "table"),
                kind: .table(convertTable(tbl))))
        case .mathBlock(let s):
            // NativeTranscript2 不渲染数学公式,降级为代码块预览,起码内容不丢。
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "math"),
                kind: .codeBlock(language: "math", code: s)))
        case .thematicBreak:
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "hr"),
                kind: .thematicBreak))
        }
    }

    private static func appendBlock(_ block: MarkdownBlock, idPrefix: String,
                                    into out: inout [Block]) {
        switch block {
        case .paragraph(let inlines):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "para"),
                kind: .paragraph(inlines: convertInlines(inlines))))
        case .heading(let level, let children):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "heading"),
                kind: .heading(level: level, inlines: convertInlines(children))))
        case .blockquote(let inner):
            out.append(Block(
                id: StableBlockID.derive(idPrefix, "blockquote"),
                kind: .blockquote(inlines: flattenToInlines(inner))))
        case .list(let list):
            out.append(Block(
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
            // 退化为纯文本组合,保留可读性
            return inner.isEmpty ? .text(dest) : wrapText(inner)
        case .image(_, let alt):
            return .text("[image: \(alt)]")
        case .inlineMath(let s):
            return .code(s)
        case .lineBreak:
            return .lineBreak
        case .softBreak:
            // CommonMark: softbreak 等价于空格;保留单空格让 wrap 算法自然处理
            return .text(" ")
        }
    }

    private static func wrapText(_ inlines: [InlineNode]) -> InlineNode {
        // 把多个 inline 包成单个节点的简单办法:用 strong 但去掉粗体语义会丢
        // 信息,改用 emphasis 同样不准。这里用 emphasis 不可,直接展平不可 —
        // 调用方期望单个 InlineNode。最终办法:返回 text(string)。
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

    /// `Block.blockquote` 只持 `[InlineNode]`,不支持嵌套 block。这里把
    /// `MarkdownBlock` 树折成纯 inline 流,paragraph 之间插 lineBreak。
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
