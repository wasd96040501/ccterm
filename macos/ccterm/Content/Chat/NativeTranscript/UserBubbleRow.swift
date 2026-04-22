import AppKit

/// User 消息右对齐气泡。
///
/// 布局：
/// - maxBubbleWidth = frame.width - bubbleMinLeftGutter - bubbleRightInset
/// - 实际 bubbleWidth = min(maxBubbleWidth, textMeasuredWidth + 2 * hPad)
/// - bubbleX = frame.width - bubbleRightInset - bubbleWidth
///
/// 短文本 hug 内容，长文本 wrap 到 maxBubbleWidth。
///
/// 折叠：超阈值的气泡可折叠成 N 行 + 底部 gradient fade + 右下 chevron。
/// `makeSize` 拆成**排版 + 几何两阶段**——toggle 只触发几何阶段，不重跑 CT。
final class UserBubbleRow: TranscriptRow {
    let text: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 用户 toggle 状态。由 TranscriptController 从 `expandedUserBubbles` set
    /// 同步过来。**不进 `contentHash`**——同 stableId 的 content 未变 row carry-over，
    /// controller 负责在 layout pass 前 sync 本字段到当前 set。
    var isExpanded: Bool = false

    private var textLayout: TranscriptTextLayout = .empty
    private var bubbleRect: CGRect = .zero
    private var textOriginInRow: CGPoint = .zero
    private var bubbleWidth: CGFloat = 0
    private var bubbleX: CGFloat = 0

    /// 上一次 `makeSize` 跑布局时采用的 `isExpanded` 值（**输入快照**，不是
    /// 排版结果缓存——和 `cachedWidth` / `cachedHeight` 语义不同）。用来识别
    /// 「宽度没变、但 state 刚翻」的场景，从而走几何分支，不重跑 CT。
    private var lastLayoutExpanded: Bool = false

    /// 由 selection controller 写入。
    fileprivate var currentSelection: NSRange = NSRange(location: NSNotFound, length: 0)

    init(text: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.text = text
        self.theme = theme
        self.stable = stable
        super.init()
    }

    /// Adopts a precomputed `UserPrepared`. Layout is width-dependent, so the
    /// caller follows up with `applyLayout(_:)` once a concrete width is
    /// known.
    init(prepared: UserPrepared, theme: TranscriptTheme) {
        self.text = prepared.text
        self.theme = theme
        self.stable = prepared.stable
        super.init()
    }

    /// Adopts a precomputed `UserLayoutData` — text layout + bubble geometry
    /// already computed off-main by `TranscriptPrepare.layoutUser`.
    func applyLayout(_ layout: UserLayoutData) {
        self.textLayout = layout.textLayout
        self.bubbleRect = layout.bubbleRect
        self.textOriginInRow = layout.textOriginInRow
        self.bubbleWidth = layout.bubbleWidth
        self.bubbleX = layout.bubbleX
        self.cachedHeight = layout.cachedHeight
        self.cachedWidth = layout.cachedWidth
        self.lastLayoutExpanded = layout.lastLayoutExpanded
    }

    /// 显式标注：Swift 6 子类 deinit 不自动继承父类 nonisolated 属性，
    /// 需要逐层声明才能真正跳过 executor-hop。见 `TranscriptRow.deinit`。
    nonisolated deinit { }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(text)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - Collapse state helpers

    /// 行数够长到有折叠资格——chevron 是否显示、hit test 是否响应都读它。
    var canCollapse: Bool {
        textLayout.lines.count >= theme.userBubbleCollapseThreshold + theme.userBubbleMinHiddenLines
    }

    /// 当前是否处于折叠态（= 够长 + 未展开）。
    var shouldCollapse: Bool { canCollapse && !isExpanded }

    override func makeSize(width: CGFloat) {
        let widthChanged = width != cachedWidth
        let stateChanged = lastLayoutExpanded != isExpanded
        guard widthChanged || stateChanged else { return }

        // 排版阶段：仅 widthChanged 时跑 CT。textLayout / bubbleWidth / bubbleX
        // 都只依赖 (text, width)，toggle 不影响。
        if widthChanged {
            cachedWidth = width
            let maxBubbleWidth = max(120, width - theme.bubbleMinLeftGutter - theme.bubbleRightInset)
            let contentMaxWidth = max(40, maxBubbleWidth - 2 * theme.bubbleHorizontalPadding)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: theme.markdown.bodyFont,
                .foregroundColor: theme.markdown.primaryColor,
            ]
            let attr = NSAttributedString(string: text, attributes: attrs)
            textLayout = TranscriptTextLayout.make(
                attributed: attr,
                maxWidth: contentMaxWidth)

            bubbleWidth = min(
                maxBubbleWidth,
                textLayout.measuredWidth + 2 * theme.bubbleHorizontalPadding)
            bubbleX = width - theme.bubbleRightInset - bubbleWidth
        }

        // 几何阶段：widthChanged 或 stateChanged 都走。
        let bubbleHeight = computeBubbleHeight()
        bubbleRect = CGRect(
            x: bubbleX,
            y: theme.rowVerticalPadding,
            width: bubbleWidth,
            height: bubbleHeight)
        textOriginInRow = CGPoint(
            x: bubbleRect.minX + theme.bubbleHorizontalPadding,
            y: bubbleRect.minY + theme.bubbleVerticalPadding)
        cachedHeight = bubbleHeight + 2 * theme.rowVerticalPadding
        lastLayoutExpanded = isExpanded
    }

    private func computeBubbleHeight() -> CGFloat {
        guard shouldCollapse,
              textLayout.lineRects.indices.contains(theme.userBubbleCollapseThreshold - 1) else {
            return textLayout.totalHeight + 2 * theme.bubbleVerticalPadding
        }
        let visibleHeight = textLayout.lineRects[theme.userBubbleCollapseThreshold - 1].maxY
        return visibleHeight + 2 * theme.bubbleVerticalPadding
    }

    override func draw(in ctx: CGContext, bounds: CGRect) {
        guard !textLayout.lines.isEmpty else { return }
        let path = CGPath(
            roundedRect: bubbleRect,
            cornerWidth: theme.bubbleCornerRadius,
            cornerHeight: theme.bubbleCornerRadius,
            transform: nil)

        // 1) Bubble fill —— 永远满 alpha，不被 mask 影响。
        ctx.saveGState()
        ctx.setFillColor(theme.bubbleFillColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // 2) 文字画在 transparency layer 里，独立做 alpha mask，不影响 bubble fill。
        //    对齐 Telegram FoldingTextView 的 CALayer.mask 技术——用 alpha gradient
        //    mask 只切文字。直接在 bubble 上叠 opaque gradient 会同时遮住气泡色 +
        //    背景色，导致末端"背景被糊掉"的丑效果。
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let sel: NSRange? = (currentSelection.location != NSNotFound && currentSelection.length > 0)
            ? currentSelection : nil
        textLayout.draw(origin: textOriginInRow, selection: sel, in: ctx)

        if shouldCollapse {
            applyTextFadeMask(in: ctx)
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 3) Chevron 不进 clip 不进 transparency layer——永远满 alpha。
        if canCollapse {
            drawChevron(in: ctx)
        }
    }

    /// Destination-in alpha mask：transparency layer 里的文字按 alpha gradient
    /// 被保留/擦除；gradient alpha 从 top→fade start 恒 1，fade start→bottom
    /// 线性降到 0。等价 Telegram `generateMaskImage` + CALayer mask。
    private func applyTextFadeMask(in ctx: CGContext) {
        let fadeHeight = min(theme.collapseFadeHeight, bubbleRect.height)
        let fadeStartY = bubbleRect.maxY - fadeHeight
        let startT = (fadeStartY - bubbleRect.minY) / bubbleRect.height

        let colors: [CGColor] = [
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        let locations: [CGFloat] = [0, startT, 1]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations) else { return }

        ctx.saveGState()
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bubbleRect.minY),
            end: CGPoint(x: 0, y: bubbleRect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func drawChevron(in ctx: CGContext) {
        let rect = chevronDrawRect()
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let halfW = rect.width / 2
        let halfH = rect.height / 2 * 0.7

        // ⌄（折叠态，向下） vs ⌃（展开态，向上）
        let path = CGMutablePath()
        if isExpanded {
            // ⌃: 左下 → 顶中 → 右下
            path.move(to: CGPoint(x: mid.x - halfW, y: mid.y + halfH / 2))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y - halfH / 2))
            path.addLine(to: CGPoint(x: mid.x + halfW, y: mid.y + halfH / 2))
        } else {
            // ⌄: 左上 → 底中 → 右上
            path.move(to: CGPoint(x: mid.x - halfW, y: mid.y - halfH / 2))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y + halfH / 2))
            path.addLine(to: CGPoint(x: mid.x + halfW, y: mid.y - halfH / 2))
        }

        ctx.saveGState()
        ctx.setStrokeColor(theme.markdown.primaryColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Chevron glyph 的绘制矩形（row 本地坐标）。
    private func chevronDrawRect() -> CGRect {
        CGRect(
            x: bubbleRect.maxX - theme.chevronInset - theme.chevronSize,
            y: bubbleRect.maxY - theme.chevronInset - theme.chevronSize,
            width: theme.chevronSize,
            height: theme.chevronSize)
    }

    /// Chevron 点击命中区（row 本地坐标）。`!canCollapse` 时返回 nil，
    /// mouseUp 分派据此判断是否 toggle。
    func chevronHitRectInRow() -> CGRect? {
        guard canCollapse else { return nil }
        let glyph = chevronDrawRect()
        let expand = (theme.chevronHitSize - theme.chevronSize) / 2
        return glyph.insetBy(dx: -expand, dy: -expand)
    }
}

// MARK: - TextSelectable

extension UserBubbleRow: TextSelectable {
    var selectableRegions: [SelectableTextRegion] {
        guard !textLayout.lines.isEmpty else { return [] }
        // 折叠态时把 region height 截到可见文字区域——防止 drag 起点落到隐藏行。
        // regionEnd clamp 是第二道保险；这里是第一道。
        let visibleHeight: CGFloat
        if shouldCollapse {
            visibleHeight = max(1, bubbleRect.height - 2 * theme.bubbleVerticalPadding)
        } else {
            visibleHeight = max(textLayout.totalHeight, 1)
        }
        let region = SelectableTextRegion(
            rowStableId: stableId,
            regionIndex: 0,
            frameInRow: CGRect(
                x: textOriginInRow.x,
                y: textOriginInRow.y,
                width: max(textLayout.measuredWidth, 1),
                height: visibleHeight),
            layout: textLayout,
            setSelection: { [weak self] range in
                self?.currentSelection = range
            })
        return [region]
    }

    var selectionHeader: String? { nil }

    func clearSelection() {
        currentSelection = NSRange(location: NSNotFound, length: 0)
    }
}
