import AppKit
import SwiftUI

/// Assistant 消息（纯文本部分），Fragment 化后的实现。
///
/// 三段分离：
/// 1. **Parse（init 时同步 / prepare 阶段 off-main）**：`MarkdownDocument(parsing:)` 拆 segment。
/// 2. **Prebuild（parse 后 / highlight 回灌后）**：每个 segment 转成「宽度无关」
///    中间物（`PrebuiltSegment`）。syntax highlight 未就绪前 code block 用 plain
///    monospaced；`applyTokens(_:)` 回灌后重 build 一次。
/// 3. **Layout + Fragment（main 或 prepare 阶段）**：按宽度喂 `TranscriptPrepare.layoutAssistant`
///    得到 `RenderedSegment`，随后转成 `[Fragment]`——draw / selection / hit
///    / highlight 回灌都从 fragment 走，row 本身不再 override `draw`。
///
/// `RenderedSegment` 仍由 `TranscriptPrepare.layoutAssistant` 输出（off-main
/// 产出 sendable 版本），`applyLayout(_:)` 把它一次性转为 fragments；width
/// 变化时 `fragments(width:)` 再次调 `layoutAssistant` + 转换（main 上跑）。
final class AssistantMarkdownRow: TranscriptRow, FragmentRow {
    let source: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 一次性 parse 的结果。
    private let parsedDocument: MarkdownDocument

    /// 宽度无关的预构造物——和 `parsedDocument.segments` 一一对应。
    private var prebuilt: [PrebuiltSegment] = []

    /// 最近一次 copy 命中的 segment index。代表 copy 反馈期内该 code block 的
    /// header 图标应渲染为 checkmark 而非 copy。由 `markCodeBlockCopied` 设置，
    /// 1.2s 后由 DispatchWorkItem 清空并触发 redraw。
    /// 自定义 fragment 的 draw 闭包 `[weak self]` 读这个字段做即时切换。
    private var copiedSegmentIndex: Int?
    private var copiedResetWork: DispatchWorkItem?

    init(source: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.source = source
        self.theme = theme
        self.stable = stable
        self.parsedDocument = MarkdownDocument(parsing: source)
        super.init()
        self.prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens: [:])
    }

    /// Adopts a precomputed `AssistantPrepared` — parse + prebuild already done
    /// off-main by `TranscriptPrepare.assistant`. O(1) alternative to
    /// `init(source:theme:stable:)`.
    init(prepared: AssistantPrepared, theme: TranscriptTheme) {
        self.source = prepared.source
        self.theme = theme
        self.stable = prepared.stable
        self.parsedDocument = prepared.parsedDocument
        super.init()
        self.prebuilt = prepared.prebuilt
    }

    /// 显式标注：Swift 6 子类 deinit 不自动继承父类 nonisolated 属性，
    /// 需要逐层声明才能真正跳过 executor-hop。见 `TranscriptRow.deinit`。
    nonisolated deinit { }

    /// Adopts a precomputed `AssistantLayoutData` — CoreText already run
    /// off-main by `TranscriptPrepare.layoutAssistant`. 直接把 `rendered` 转
    /// 成 fragments 缓存起来，下一次 draw 命中 O(1) 路径。
    func applyLayout(_ layout: AssistantLayoutData) {
        self.cachedWidth = layout.cachedWidth
        self.cachedHeight = layout.cachedHeight
        syncTableSelections(with: layout.tableSelectionsSkeleton)
        self.cachedFragments = Self.buildFragments(
            rendered: layout.rendered,
            theme: theme,
            rowWidth: layout.cachedWidth,
            copiedProvider: { [weak self] in self?.copiedSegmentIndex }).fragments
    }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(source)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - FragmentRow

    /// 宽度变了才会被基类 `makeSize` 调用。直接在 main 上重跑 layoutAssistant，
    /// 然后转成 fragments。重活集中在 `TranscriptTextLayout.make`（CTTypesetter），
    /// 和 prepare 阶段一致。
    func fragments(width: CGFloat) -> FragmentLayout {
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prebuilt, theme: theme, width: width)
        syncTableSelections(with: layout.tableSelectionsSkeleton)
        let built = Self.buildFragments(
            rendered: layout.rendered,
            theme: theme,
            rowWidth: width,
            copiedProvider: { [weak self] in self?.copiedSegmentIndex })
        // `layout.cachedHeight` 包含顶/底 rowVerticalPadding（任何 fragment
        // 都摸不到），这里用它替代 fragment maxY 推断，保证行高精确。
        return FragmentLayout(fragments: built.fragments, height: layout.cachedHeight)
    }

    /// Highlight 回灌：重 build prebuilt（带彩色），清 fragment 缓存 +
    /// 选中状态。基类的下一次 `makeSize` 会触发 `fragments(width:)` 重排。
    /// Tokens 的 key 是 `segmentIndex`（Int），从 protocol 的 `AnyHashable`
    /// unbox 回来——只处理 Int keys，其他类型的 key 属于其他 row 的业务被忽略。
    func applyTokens(_ tokens: [AnyHashable: [SyntaxToken]]) {
        var codeTokens: [Int: [SyntaxToken]] = [:]
        for (key, value) in tokens {
            if let i = key.base as? Int {
                codeTokens[i] = value
            }
        }
        prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens: codeTokens)
        cachedWidth = 0
        cachedFragments = []
        copiedResetWork?.cancel()
        copiedResetWork = nil
        copiedSegmentIndex = nil
        clearFragmentSelections()
    }

    /// 暴露给 preprocessor 的请求列表：`(segmentIndex, code, language)`。
    var codeBlockRequests: [(segmentIndex: Int, code: String, language: String?)] {
        var out: [(Int, String, String?)] = []
        for (i, seg) in parsedDocument.segments.enumerated() {
            if case .codeBlock(let block) = seg {
                out.append((i, block.code, block.language))
            }
        }
        return out
    }

    // MARK: - Selection skeleton

    /// No-op under the new unified `SelectionStore` — the store is
    /// `[AnyHashable: NSRange]` on the base class and survives fragment
    /// rebuilds on its own. `TableCellKey(base: idx, row:, col:)` remains
    /// stable across layouts as long as `idx` (segment index) is stable.
    /// Kept as a private stub so build-sites don't need to be edited off
    /// this file in the same step; removed in a follow-up cleanup.
    private func syncTableSelections(with skeleton: Any) {
        // Unified SelectionStore on TranscriptRow handles preservation
        // across rebuilds — per-cell NSRange is keyed by a stable struct,
        // not wiped on each layout adoption.
    }

    // MARK: - Click-to-copy API (kept for TranscriptController compatibility)

    /// Code block header hit info — segmentIndex lets callers flip the icon
    /// to a transient checkmark on the exact header that was clicked.
    struct CodeBlockHitInfo {
        let segmentIndex: Int
        let code: String
    }

    /// Thin adapter over the base class `hit(at:)`. Controller still calls
    /// this by name; we just unwrap the generic `HitAction.copyCode` back
    /// into the row-specific `CodeBlockHitInfo` contract.
    func codeBlockHit(atRowPoint pointInRow: CGPoint) -> CodeBlockHitInfo? {
        guard case let .copyCode(code, tag)? = hit(at: pointInRow) else {
            return nil
        }
        return CodeBlockHitInfo(segmentIndex: tag, code: code)
    }

    /// Flips the target code block's icon to a checkmark for `dwell` seconds,
    /// then reverts. Caller passes a `redraw` closure to force a repaint on
    /// both transitions — the row doesn't own the table view.
    func markCodeBlockCopied(
        segmentIndex: Int,
        dwell: TimeInterval = 1.2,
        redraw: @escaping () -> Void
    ) {
        copiedResetWork?.cancel()
        copiedSegmentIndex = segmentIndex
        redraw()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedSegmentIndex = nil
            self.copiedResetWork = nil
            redraw()
        }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    // MARK: - Fragment builder

    /// Convert a laid-out `RenderedSegment` list into `FragmentLayout`. The
    /// height field is **not** populated here (caller decides, typically
    /// from `AssistantLayoutData.cachedHeight` which includes the row's top/
    /// bottom v-padding); the returned `height` is max-maxY over fragments,
    /// safe fallback for ad-hoc calls.
    ///
    /// Pure helper — per performance rule #2, does not capture `self`; the
    /// copy icon's state is pulled via `copiedProvider` (a `[weak self]`
    /// closure passed in from the instance). One weak deref per paint per
    /// code block.
    private static func buildFragments(
        rendered: [RenderedSegment],
        theme: TranscriptTheme,
        rowWidth: CGFloat,
        copiedProvider: @escaping () -> Int?
    ) -> FragmentLayout {
        var out: [Fragment] = []
        let contentWidth = max(40, rowWidth - 2 * theme.rowHorizontalPadding)

        for (idx, seg) in rendered.enumerated() {
            switch seg {
            case .attributed(let layout, let kind, let origin):
                switch kind {
                case .text, .heading:
                    out.append(.text(TextFragment(
                        layout: layout,
                        origin: origin,
                        selectionKey: idx)))

                case .blockquote:
                    let barW = theme.markdown.blockquoteBarWidth
                    let barGap = theme.markdown.blockquoteBarGap
                    let barX = origin.x - barGap - barW
                    out.append(.rect(RectFragment(
                        frame: CGRect(
                            x: barX, y: origin.y,
                            width: barW, height: layout.totalHeight),
                        style: .fill(
                            theme.markdown.blockquoteBarColor,
                            cornerRadius: 1))))
                    out.append(.text(TextFragment(
                        layout: layout,
                        origin: origin,
                        selectionKey: idx)))

                case .codeBlock(let header):
                    // Body outline (full block including header).
                    let bodyRect = CGRect(
                        x: theme.rowHorizontalPadding,
                        y: origin.y - theme.codeBlockVerticalPadding - theme.codeBlockHeaderHeight,
                        width: contentWidth,
                        height: layout.totalHeight
                            + 2 * theme.codeBlockVerticalPadding
                            + theme.codeBlockHeaderHeight)
                    out.append(.rect(RectFragment(
                        frame: bodyRect,
                        style: .fill(
                            theme.markdown.codeBlockBackground,
                            cornerRadius: theme.codeBlockCornerRadius))))

                    // Header strip — rounded top, square bottom so it meets
                    // the body cleanly without diagonal slivers.
                    let headerRect = CGRect(
                        x: bodyRect.minX, y: bodyRect.minY,
                        width: bodyRect.width,
                        height: theme.codeBlockHeaderHeight)
                    out.append(.rect(RectFragment(
                        frame: headerRect,
                        style: .fillPerCorner(
                            theme.codeBlockHeaderBackground,
                            topLeft: theme.codeBlockCornerRadius,
                            topRight: theme.codeBlockCornerRadius,
                            bottomLeft: 0,
                            bottomRight: 0))))

                    // Language label (optional).
                    if let langLine = header.line {
                        let glyphHeight = header.ascent + header.descent
                        let labelTop = headerRect.minY
                            + (theme.codeBlockHeaderHeight - glyphHeight) / 2
                        let labelWidth = CGFloat(CTLineGetTypographicBounds(
                            langLine, nil, nil, nil))
                        out.append(.line(LineFragment(
                            line: langLine,
                            origin: CGPoint(
                                x: headerRect.minX + theme.codeBlockHeaderLabelInsetX,
                                y: labelTop),
                            ascent: header.ascent,
                            descent: header.descent,
                            width: labelWidth)))
                    }

                    // Copy / checkmark icon (right-aligned in header). The
                    // draw closure reads the row's `copiedSegmentIndex` via
                    // `copiedProvider`; the hit action fires a `.copyCode`
                    // back to the controller.
                    let iconSide = theme.codeBlockHeaderIconSize
                    let iconRect = CGRect(
                        x: headerRect.maxX - theme.codeBlockHeaderIconInsetX - iconSide,
                        y: headerRect.minY + (theme.codeBlockHeaderHeight - iconSide) / 2,
                        width: iconSide,
                        height: iconSide)
                    let tint = theme.codeBlockHeaderForeground
                    let segTag = idx
                    let code = header.code
                    out.append(.custom(CustomFragment(
                        frame: iconRect,
                        draw: { ctx, rect in
                            if copiedProvider() == segTag {
                                Self.drawCheckmarkIcon(in: ctx, rect: rect, tint: tint)
                            } else {
                                Self.drawCopyIcon(in: ctx, rect: rect, tint: tint)
                            }
                        },
                        hit: .copyCode(code: code, segmentTag: segTag))))

                    // Code body text — selectable + highlightable.
                    out.append(.text(TextFragment(
                        layout: layout,
                        origin: origin,
                        selectionKey: idx,
                        highlightKey: idx)))
                }

            case .list(let listLayout, let origin):
                out.append(.list(ListFragment(
                    layout: listLayout,
                    origin: origin,
                    selectionKeyBase: idx)))

            case .table(let tableLayout, let origin):
                out.append(.table(TableFragment(
                    layout: tableLayout,
                    origin: origin,
                    selectionKeyBase: idx)))

            case .thematicBreak(let y):
                out.append(.rect(RectFragment(
                    frame: CGRect(
                        x: theme.rowHorizontalPadding,
                        y: y + 0.5,
                        width: rowWidth - 2 * theme.rowHorizontalPadding,
                        height: 1),
                    style: .stroke(
                        NSColor.separatorColor,
                        lineWidth: 1))))
            }
        }

        let maxY = out.reduce(0) { max($0, $1.frame.maxY) }
        return FragmentLayout(fragments: out, height: maxY)
    }

    // MARK: - Static CG icons (shared with CustomFragment draw closures)

    /// "doc.on.doc"-style glyph drawn with two stroked rounded rectangles.
    /// Pure CG — avoids shipping a template NSImage or bouncing through
    /// `NSGraphicsContext` just for a 13pt mono icon.
    fileprivate static func drawCopyIcon(
        in ctx: CGContext,
        rect: CGRect,
        tint: NSColor
    ) {
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        let stroke: CGFloat = 1.1
        let corner = side * 0.22
        let plateSide = side * 0.72
        let offset = side - plateSide

        ctx.saveGState()
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(stroke)

        // Back plate — anchored top-right.
        let back = CGRect(
            x: originX + offset,
            y: originY,
            width: plateSide,
            height: plateSide
        ).insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.addPath(CGPath(
            roundedRect: back,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil))
        ctx.strokePath()

        // Front plate — anchored bottom-left, overlapping the back.
        let front = CGRect(
            x: originX,
            y: originY + offset,
            width: plateSide,
            height: plateSide
        ).insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.addPath(CGPath(
            roundedRect: front,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil))
        ctx.strokePath()

        ctx.restoreGState()
    }

    /// Two-segment checkmark drawn in `rect`. Context is flipped (y grows
    /// down), so "lower-left → bottom → upper-right" maps to increasing then
    /// decreasing y. Line caps rounded to match the copy icon's stroke feel.
    fileprivate static func drawCheckmarkIcon(
        in ctx: CGContext,
        rect: CGRect,
        tint: NSColor
    ) {
        let side = min(rect.width, rect.height)
        let inset = side * 0.08
        let x = rect.minX + (rect.width - side) / 2 + inset
        let y = rect.minY + (rect.height - side) / 2 + inset
        let s = side - inset * 2
        let stroke = max(1.3, side * 0.12)

        ctx.saveGState()
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: x + s * 0.10, y: y + s * 0.52))
        ctx.addLine(to: CGPoint(x: x + s * 0.42, y: y + s * 0.80))
        ctx.addLine(to: CGPoint(x: x + s * 0.92, y: y + s * 0.24))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Data model (shared with TranscriptPrepare)

    enum SegmentKind {
        case text, heading, blockquote
        case codeBlock(CodeBlockHeader)
    }

    /// Header bar metadata pre-computed at prebuild time. `draw()` only has
    /// to call `CTLineDraw` (via a `.line` fragment). Fences without a
    /// language get a `nil` line — the header still renders, but only the
    /// copy affordance on the right.
    struct CodeBlockHeader {
        /// Raw code string copied on header click. Not derived from the
        /// attributed body so tokenizer boundary whitespace can't leak in.
        let code: String
        /// Pre-typeset language label ("swift", "python" …). `nil` when the
        /// fence had no language.
        let line: CTLine?
        let ascent: CGFloat
        let descent: CGFloat
    }

    enum PrebuiltSegment {
        case attributed(NSAttributedString, kind: SegmentKind, topPadding: CGFloat)
        case list(TranscriptListContents, topPadding: CGFloat)
        case table(TranscriptTableCellContents, topPadding: CGFloat)
        case thematicBreak(topPadding: CGFloat)

        var topPadding: CGFloat {
            switch self {
            case .attributed(_, _, let p),
                 .list(_, let p),
                 .table(_, let p),
                 .thematicBreak(let p):
                return p
            }
        }
    }

    /// `TranscriptPrepare.layoutAssistant` 产出的中间 layout 态——`prebuilt`
    /// 按宽度排版后的结果。随后被 `buildFragments(...)` 转换为 `[Fragment]`。
    enum RenderedSegment {
        case attributed(TranscriptTextLayout, kind: SegmentKind, layoutOrigin: CGPoint)
        case list(TranscriptListLayout, origin: CGPoint)
        case table(TranscriptTableLayout, origin: CGPoint)
        case thematicBreak(y: CGFloat)
    }

}

// Default TextSelectable conformance comes from TranscriptRow — fragment
// path自动生效，无需 per-row extension。
