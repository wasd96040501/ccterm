import AppKit
import SwiftUI

/// 把 `MarkdownDocument` 转成「宽度无关」的预构造段。
///
/// 调用时机:
/// 1. `AssistantMarkdownComponent.prepare` 同步跑(`codeTokens = [:]`,code block
///    用 plain monospaced)。
/// 2. Highlight refinement 完成后由 ContentPatch 再跑一次,用回灌的 tokens
///    重生成彩色 code block attributed string。
nonisolated enum AssistantMarkdownPrebuilder {

    static func build(
        document: MarkdownDocument,
        theme: TranscriptTheme,
        codeTokens: [Int: [SyntaxToken]]
    ) -> [AssistantMarkdownComponent.PrebuiltSegment] {
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        var out: [AssistantMarkdownComponent.PrebuiltSegment] = []
        out.reserveCapacity(document.segments.count)

        for (idx, seg) in document.segments.enumerated() {
            let gap = gapBefore(idx: idx, segment: seg, theme: theme.markdown)

            switch seg {
            case .markdown(let blocks):
                out.append(.attributed(
                    builder.build(blocks: blocks),
                    kind: .text, topPadding: gap))
            case .heading(let level, let inlines):
                out.append(.attributed(
                    builder.buildHeading(level: level, inlines: inlines),
                    kind: .heading, topPadding: gap))
            case .blockquote(let blocks):
                out.append(.attributed(
                    builder.buildBlockquote(blocks: blocks),
                    kind: .blockquote, topPadding: gap))
            case .codeBlock(let block):
                let attr = buildCodeBlockAttributed(
                    block: block, tokens: codeTokens[idx], theme: theme)
                let header = buildCodeBlockHeader(block: block, theme: theme)
                out.append(.attributed(
                    attr, kind: .codeBlock(header), topPadding: gap))
            case .list(let list):
                let contents = TranscriptListContents.make(
                    list: list, theme: theme.markdown, builder: builder)
                out.append(.list(contents, topPadding: gap))
            case .table(let table):
                let contents = TranscriptTableCellContents.make(
                    table: table, builder: builder)
                out.append(.table(contents, topPadding: gap))
            case .mathBlock(let raw):
                let attr = NSAttributedString(
                    string: raw,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: theme.markdown.codeFontSize, weight: .regular),
                        .foregroundColor: theme.markdown.primaryColor,
                    ])
                out.append(.attributed(attr, kind: .text, topPadding: gap))
            case .thematicBreak:
                out.append(.thematicBreak(topPadding: gap))
            }
        }
        return out
    }

    private static func buildCodeBlockAttributed(
        block: MarkdownCodeBlock,
        tokens: [SyntaxToken]?,
        theme: TranscriptTheme
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(
            ofSize: theme.markdown.codeFontSize, weight: .regular)
        if let tokens, !tokens.isEmpty {
            let result = NSMutableAttributedString()
            for token in tokens {
                let scope = token.scope
                let color = NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                    let scheme: ColorScheme = match == .darkAqua ? .dark : .light
                    return NSColor(SyntaxTheme.color(for: scope, scheme: scheme))
                }
                result.append(NSAttributedString(string: token.text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            }
            return result
        }
        return NSAttributedString(
            string: block.code,
            attributes: [
                .font: font,
                .foregroundColor: theme.markdown.primaryColor,
            ])
    }

    private static func buildCodeBlockHeader(
        block: MarkdownCodeBlock,
        theme: TranscriptTheme
    ) -> AssistantMarkdownComponent.CodeBlockHeader {
        let raw = (block.language ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !raw.isEmpty else {
            return AssistantMarkdownComponent.CodeBlockHeader(
                code: block.code, line: nil, ascent: 0, descent: 0)
        }
        let font = NSFont.systemFont(
            ofSize: theme.codeBlockHeaderFontSize, weight: .medium)
        let attr = NSAttributedString(
            string: raw,
            attributes: [
                .font: font,
                .foregroundColor: theme.codeBlockHeaderForeground,
            ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return AssistantMarkdownComponent.CodeBlockHeader(
            code: block.code, line: line, ascent: ascent, descent: descent)
    }

    private static func gapBefore(
        idx: Int, segment: MarkdownSegment, theme: MarkdownTheme
    ) -> CGFloat {
        if idx == 0 { return 0 }
        if case .heading = segment { return theme.l1 }
        return theme.l2
    }
}
