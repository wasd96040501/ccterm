import AppKit
import SwiftUI

/// 把 `MarkdownDocument` 转成「宽度无关」的预构造段（`AssistantMarkdownRow.PrebuiltSegment`）。
///
/// 拆出来的目的是把 parse-output → layout-input 这一段重的转换流程
/// 和 `AssistantMarkdownRow` 的 per-instance 状态、layout、绘制解耦——
/// row 文件本来逼近 700 行，prebuild 又是和 instance 状态正交的纯函数。
///
/// 调用时机：
/// 1. `AssistantMarkdownRow.init` 时同步跑一次（`codeTokens = [:]`，code block
///    用 plain monospaced 字体）。
/// 2. `TranscriptPreprocessor` 的 syntax highlight Task 完成后由
///    `AssistantMarkdownRow.apply(codeTokens:)` 再跑一次，用回灌的 tokens
///    重新生成彩色的 code block attributed string。
enum MarkdownRowPrebuilder {

    /// 主入口：遍历 segments，按类型分派到具体 builder。
    static func build(
        document: MarkdownDocument,
        theme: TranscriptTheme,
        codeTokens: [Int: [SyntaxToken]]
    ) -> [AssistantMarkdownRow.PrebuiltSegment] {
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        var out: [AssistantMarkdownRow.PrebuiltSegment] = []
        out.reserveCapacity(document.segments.count)

        for (idx, seg) in document.segments.enumerated() {
            let gap = gapBefore(idx: idx, segment: seg, theme: theme.markdown)

            switch seg {
            case .markdown(let blocks):
                out.append(.attributed(builder.build(blocks: blocks), kind: .text, topPadding: gap))
            case .heading(let level, let inlines):
                out.append(.attributed(builder.buildHeading(level: level, inlines: inlines), kind: .heading, topPadding: gap))
            case .blockquote(let blocks):
                out.append(.attributed(builder.buildBlockquote(blocks: blocks), kind: .blockquote, topPadding: gap))
            case .codeBlock(let block):
                let attr = buildCodeBlockAttributed(
                    block: block,
                    tokens: codeTokens[idx],
                    theme: theme)
                let header = buildCodeBlockHeader(block: block, theme: theme)
                out.append(.attributed(attr, kind: .codeBlock(header), topPadding: gap))
            case .table(let table):
                let contents = TranscriptTableCellContents.make(table: table, builder: builder)
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

    /// Code block body 文本：有 tokens 走 syntax-aware 多色 attributed string，
    /// 没 tokens（首屏未 highlight）走 plain monospaced 单色，避免空 attr 渲染异常。
    private static func buildCodeBlockAttributed(
        block: MarkdownCodeBlock,
        tokens: [SyntaxToken]?,
        theme: TranscriptTheme
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(
            ofSize: theme.markdown.codeFontSize, weight: .regular)
        if let tokens, !tokens.isEmpty {
            // Build with dynamic NSColors — the attributed string outlives the
            // current appearance (it's cached in the layout). Each token's
            // color resolves at draw time via
            // `NSAppearance.performAsCurrentDrawingAppearance` in the row view,
            // so switching system appearance doesn't need a token rebuild.
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

    /// Pre-lays out the language label CTLine. Done once at prebuild time
    /// so `draw()` only has to call `CTLineDraw`. Fences without a language
    /// get a `nil` line — the header still renders, but only the copy icon.
    private static func buildCodeBlockHeader(
        block: MarkdownCodeBlock,
        theme: TranscriptTheme
    ) -> AssistantMarkdownRow.CodeBlockHeader {
        let raw = (block.language ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !raw.isEmpty else {
            return AssistantMarkdownRow.CodeBlockHeader(code: block.code, line: nil, ascent: 0, descent: 0)
        }
        let font = NSFont.systemFont(
            ofSize: theme.codeBlockHeaderFontSize,
            weight: .medium)
        let attr = NSAttributedString(
            string: raw,
            attributes: [
                .font: font,
                .foregroundColor: theme.codeBlockHeaderForeground,
            ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return AssistantMarkdownRow.CodeBlockHeader(
            code: block.code,
            line: line,
            ascent: ascent,
            descent: descent)
    }

    private static func gapBefore(idx: Int, segment: MarkdownSegment, theme: MarkdownTheme) -> CGFloat {
        if idx == 0 { return 0 }
        if case .heading = segment { return theme.l1 }
        return theme.l2
    }
}
