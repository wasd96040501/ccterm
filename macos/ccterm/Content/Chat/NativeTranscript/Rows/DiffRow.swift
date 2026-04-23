import AppKit
import CoreText

/// Edit / Write 工具调用的 diff 视图。Fragment 化实现——每行产生 `.rect`
/// （line bg + gutter bg）+ `.line`（行号 + sign）+ `.text`（wrapped 内容）。
///
/// Pipeline 与 `AssistantMarkdownRow` 对齐：
/// - off-main prepare: `TranscriptPrepare.diff` + `layoutDiff` 产出
///   `DiffPrepared` + `DiffLayoutData`
/// - main adopt: `applyLayout(_:)` 把 layout 转成 `[Fragment]`
/// - width change: `fragments(width:)` 在 main 上重跑 `layoutDiff` 再转换
/// - highlight 回灌（step 5）: `applyTokens(_:)` 用内容 string 作 key 接回
///   tokens，存进 prepared 的 `lineHighlights`，清缓存触发重排
final class DiffRow: TranscriptRow, FragmentRow {
    private(set) var prepared: DiffPrepared
    let theme: TranscriptTheme

    init(prepared: DiffPrepared, theme: TranscriptTheme) {
        self.prepared = prepared
        self.theme = theme
        super.init()
    }

    /// 显式标注：Swift 6 子类 deinit 不自动继承父类 nonisolated 属性，
    /// 需要逐层声明才能真正跳过 executor-hop。见 `TranscriptRow.deinit`。
    nonisolated deinit { }

    override var stableId: AnyHashable { prepared.stable }

    override var contentHash: Int { prepared.contentHash }

    /// Adopts a precomputed `DiffLayoutData` — CoreText already run off-main
    /// by `TranscriptPrepare.layoutDiff`. 把 entries 转成 `[Fragment]`。
    func applyLayout(_ layout: DiffLayoutData) {
        self.cachedWidth = layout.cachedWidth
        self.cachedHeight = layout.cachedHeight
        self.cachedFragments = Self.buildFragments(layout: layout, theme: theme)
    }

    // MARK: - FragmentRow

    func fragments(width: CGFloat) -> FragmentLayout {
        let layout = TranscriptPrepare.layoutDiff(
            prepared: prepared, theme: theme, width: width)
        let frags = Self.buildFragments(layout: layout, theme: theme)
        return FragmentLayout(fragments: frags, height: layout.cachedHeight)
    }

    /// Highlight 回灌入口（step 5 正式启用；MVP 先打桩）。tokens 的 key 是
    /// 行内容 `content`（AnyHashable-wrap 的 String）。
    func applyTokens(_ tokens: [AnyHashable: [SyntaxToken]]) {
        var lineHighlights: [String: [SyntaxToken]] = prepared.lineHighlights
        var changed = false
        for (key, val) in tokens {
            guard let content = key.base as? String else { continue }
            lineHighlights[content] = val
            changed = true
        }
        guard changed else { return }
        prepared = DiffPrepared(
            filePath: prepared.filePath,
            hunks: prepared.hunks,
            language: prepared.language,
            suppressInsertionStyle: prepared.suppressInsertionStyle,
            stable: prepared.stable,
            contentHash: prepared.contentHash,
            lineHighlights: lineHighlights,
            hasHighlight: true)
        cachedWidth = 0
        cachedFragments = []
        clearFragmentSelections()
    }

    // MARK: - Fragment builder

    /// Convert a `DiffLayoutData` into `[Fragment]`. Pure helper — no `self`
    /// capture, so the produced fragments satisfy performance rule #2.
    private static func buildFragments(
        layout: DiffLayoutData,
        theme: TranscriptTheme
    ) -> [Fragment] {
        var out: [Fragment] = []

        // Outer rounded container bg.
        out.append(.rect(RectFragment(
            frame: layout.containerRect,
            style: .fill(DiffColors.dynamicTableBg, cornerRadius: 6))))

        // Header bar (basename + optional language tag). Baseline-centered.
        let headerGlyphH = layout.headerAscent + layout.headerDescent
        let headerBaselineTop = layout.headerRect.minY
            + (layout.headerRect.height - headerGlyphH) / 2
        out.append(.line(LineFragment(
            line: layout.headerLine,
            origin: CGPoint(
                x: layout.headerRect.minX + 10,
                y: headerBaselineTop),
            ascent: layout.headerAscent,
            descent: layout.headerDescent,
            width: layout.headerWidth)))

        // Body entries (lines + hunk separators).
        for entry in layout.entries {
            switch entry {
            case .line(let e):
                appendLineFragments(entry: e, layout: layout, into: &out)
            case .separator(let e):
                appendSeparatorFragments(entry: e, layout: layout, into: &out)
            }
        }

        return out
    }

    private static func appendLineFragments(
        entry: DiffLineEntry,
        layout: DiffLayoutData,
        into out: inout [Fragment]
    ) {
        let containerRight = layout.containerRect.maxX

        // Full-width line background (add/del/context color, context = clear).
        let fullBgRect = CGRect(
            x: layout.containerRect.minX,
            y: entry.y,
            width: layout.containerRect.width,
            height: entry.height)
        if entry.type != .context {
            out.append(.rect(RectFragment(
                frame: fullBgRect,
                style: .fill(DiffColors.dynamicContentBg(entry.type)))))
        }

        // Gutter (line-number column) background — darker than full line bg,
        // spans line-no + sign columns together.
        let gutterBgRect = CGRect(
            x: layout.lineNoColumnX,
            y: entry.y,
            width: layout.lineNoColumnWidth + layout.signColumnWidth,
            height: entry.height)
        out.append(.rect(RectFragment(
            frame: gutterBgRect,
            style: .fill(DiffColors.dynamicGutterBg(entry.type)))))

        // Line number — right-aligned inside the line-no column, single CTLine.
        let monoFont = layout.monoFont
        if !entry.lineNoText.isEmpty {
            let padded = String(repeating: " ",
                count: max(0, layout.gutterDigits - entry.lineNoText.count))
                + entry.lineNoText
            let lineNoAttr = NSAttributedString(
                string: " \(padded) ",
                attributes: [
                    .font: monoFont,
                    .foregroundColor: DiffColors.dynamicGutterText,
                ])
            let lineNoLine = CTLineCreateWithAttributedString(lineNoAttr)
            var lnAsc: CGFloat = 0, lnDesc: CGFloat = 0, lnLead: CGFloat = 0
            let lnWidth = CGFloat(CTLineGetTypographicBounds(
                lineNoLine, &lnAsc, &lnDesc, &lnLead))
            // Top-align line number with the content's first visual line.
            let lineNoTop = entry.y + (layout.monoLineHeight - (lnAsc + lnDesc)) / 2
            out.append(.line(LineFragment(
                line: lineNoLine,
                origin: CGPoint(x: layout.lineNoColumnX, y: lineNoTop),
                ascent: lnAsc,
                descent: lnDesc,
                width: lnWidth)))
        }

        // Sign column — " + ", " - ", or " " (invisible).
        let sign: String
        let signColor: NSColor
        switch entry.type {
        case .add:
            sign = " + "
            signColor = DiffColors.dynamicSignAdd
        case .del:
            sign = " - "
            signColor = DiffColors.dynamicSignDel
        case .context:
            sign = "   "
            signColor = .clear
        }
        if entry.type != .context {
            let signAttr = NSAttributedString(
                string: sign,
                attributes: [
                    .font: monoFont,
                    .foregroundColor: signColor,
                ])
            let signLine = CTLineCreateWithAttributedString(signAttr)
            var sAsc: CGFloat = 0, sDesc: CGFloat = 0, sLead: CGFloat = 0
            let sWidth = CGFloat(CTLineGetTypographicBounds(
                signLine, &sAsc, &sDesc, &sLead))
            let signTop = entry.y + (layout.monoLineHeight - (sAsc + sDesc)) / 2
            out.append(.line(LineFragment(
                line: signLine,
                origin: CGPoint(x: layout.signColumnX, y: signTop),
                ascent: sAsc,
                descent: sDesc,
                width: sWidth)))
        }

        // Content text (wrapped).
        out.append(.text(TextFragment(
            layout: entry.contentLayout,
            origin: CGPoint(x: layout.contentColumnX, y: entry.y),
            selectionTag: nil,       // 选中先不接（follow-up plan）
            highlightTag: nil)))     // highlightTag 步骤 5 再赋值

        _ = containerRight  // reserved for future header icons
    }

    private static func appendSeparatorFragments(
        entry: DiffSeparatorEntry,
        layout: DiffLayoutData,
        into out: inout [Fragment]
    ) {
        // Separator is a faded "···" strip spanning the container width.
        let rect = CGRect(
            x: layout.containerRect.minX,
            y: entry.y,
            width: layout.containerRect.width,
            height: entry.height)
        out.append(.rect(RectFragment(
            frame: rect,
            style: .fill(DiffColors.dynamicSeparatorBg))))

        let attr = NSAttributedString(
            string: " ··· ",
            attributes: [
                .font: layout.monoFont,
                .foregroundColor: DiffColors.dynamicSeparatorFg,
            ])
        let line = CTLineCreateWithAttributedString(attr)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        let baselineTop = rect.minY + (rect.height - (asc + desc)) / 2
        out.append(.line(LineFragment(
            line: line,
            origin: CGPoint(x: rect.minX + 10, y: baselineTop),
            ascent: asc,
            descent: desc,
            width: w)))
    }
}
