import AgentSDK
import AppKit

/// User 消息右对齐气泡。超阈值可折叠。
///
/// State = `(isExpanded: Bool, selection: NSRange?)`
/// Layout 两阶段:CT layout(text → lines + 气泡 width/X,state 无关) + 几何
/// (气泡 rect + textOrigin + cachedHeight,依赖 state 的 isExpanded)。
/// `relayouted(...)` 快路径复用 CT 结果只跑几何。
enum UserBubbleComponent: TranscriptComponent {
    static let tag = "UserBubble"

    struct Input: Sendable {
        let stableId: StableId
        let text: String
    }

    struct Content: Sendable {
        let text: String
    }

    struct Layout: HasHeight, @unchecked Sendable {
        /// CT 阶段产物 —— state 无关,width 变了才需要重跑。
        let textLayout: TranscriptTextLayout
        let bubbleWidth: CGFloat
        let bubbleX: CGFloat

        /// 几何阶段产物 —— 依赖 state.isExpanded。
        let bubbleRect: CGRect
        let textOriginInRow: CGPoint
        let cachedHeight: CGFloat
        let cachedWidth: CGFloat
        /// 本 layout 是在 `isExpanded = ?` 下算出来的。
        let laidOutExpanded: Bool
    }

    struct State: Sendable {
        var isExpanded: Bool = false
        var selection: NSRange = NSRange(location: NSNotFound, length: 0)

        static let `default` = State()
    }

    typealias SideCar = EmptyRowSideCar

    // MARK: - Inputs

    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>] {
        guard case .single(let single) = entry else { return [] }

        let text: String?
        switch single.payload {
        case .localUser(let input):
            text = input.text
        case .remote(let message):
            if case .user(let u) = message {
                text = Self.userPlainText(u)
            } else {
                text = nil
            }
        }
        guard let t = text, !t.isEmpty else { return [] }
        let stableId = StableId(entryId: single.id, locator: .whole)
        return [IdentifiedInput(
            stableId: stableId,
            entryIndex: entryIndex,
            blockIndex: 0,
            input: Input(stableId: stableId, text: t))]
    }

    /// Concatenate visible text from Message2User's `.string` / `.array` content.
    /// Image / tool_result parts are ignored — user bubbles only show typed text.
    nonisolated private static func userPlainText(_ user: Message2User) -> String? {
        switch user.message?.content {
        case .string(let s)?:
            return s
        case .array(let items)?:
            let parts = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.text }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }

    // MARK: - Prepare

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        Content(text: input.text)
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.text)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    nonisolated static func initialState(for input: Input) -> State {
        .default
    }

    // MARK: - Layout (full CT + geometry)

    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        let ct = ctLayout(text: content.text, theme: theme, width: width)
        return geometry(ct: ct, theme: theme, width: width, state: state)
    }

    /// 快路径:width 未变,仅 state.isExpanded 影响气泡高度。复用 CT 结果,
    /// 只重跑几何。
    nonisolated static func relayouted(
        _ layout: Layout,
        theme: TranscriptTheme,
        state: State
    ) -> Layout? {
        // 若 state.isExpanded 和 layout.laidOutExpanded 一致 → 无需重算
        guard layout.laidOutExpanded != state.isExpanded else { return layout }
        return geometry(
            ct: CTCache(
                textLayout: layout.textLayout,
                bubbleWidth: layout.bubbleWidth,
                bubbleX: layout.bubbleX),
            theme: theme,
            width: layout.cachedWidth,
            state: state)
    }

    private struct CTCache {
        let textLayout: TranscriptTextLayout
        let bubbleWidth: CGFloat
        let bubbleX: CGFloat
    }

    nonisolated private static func ctLayout(
        text: String,
        theme: TranscriptTheme,
        width: CGFloat
    ) -> CTCache {
        let maxBubbleWidth = max(120, min(
            theme.userBubbleMaxWidth,
            width - theme.bubbleMinLeftGutter - theme.bubbleRightInset))
        let contentMaxWidth = max(40, maxBubbleWidth - 2 * theme.bubbleHorizontalPadding)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.markdown.bodyFont,
            .foregroundColor: theme.markdown.primaryColor,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textLayout = TranscriptTextLayout.make(
            attributed: attr, maxWidth: contentMaxWidth)

        let bubbleWidth = min(
            maxBubbleWidth,
            textLayout.measuredWidth + 2 * theme.bubbleHorizontalPadding)
        let bubbleX = width - theme.bubbleRightInset - bubbleWidth

        return CTCache(textLayout: textLayout, bubbleWidth: bubbleWidth, bubbleX: bubbleX)
    }

    nonisolated private static func geometry(
        ct: CTCache,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        let canCollapse = ct.textLayout.lines.count
            >= theme.userBubbleCollapseThreshold + theme.userBubbleMinHiddenLines
        let shouldCollapse = canCollapse && !state.isExpanded
        let bubbleHeight: CGFloat
        if shouldCollapse,
           ct.textLayout.lineRects.indices.contains(theme.userBubbleCollapseThreshold - 1) {
            let visibleHeight = ct.textLayout.lineRects[theme.userBubbleCollapseThreshold - 1].maxY
            bubbleHeight = visibleHeight + 2 * theme.bubbleVerticalPadding
        } else {
            bubbleHeight = ct.textLayout.totalHeight + 2 * theme.bubbleVerticalPadding
        }
        let bubbleRect = CGRect(
            x: ct.bubbleX,
            y: theme.rowVerticalPadding,
            width: ct.bubbleWidth,
            height: bubbleHeight)
        let textOriginInRow = CGPoint(
            x: bubbleRect.minX + theme.bubbleHorizontalPadding,
            y: bubbleRect.minY + theme.bubbleVerticalPadding)
        let cachedHeight = bubbleHeight + 2 * theme.rowVerticalPadding

        return Layout(
            textLayout: ct.textLayout,
            bubbleWidth: ct.bubbleWidth,
            bubbleX: ct.bubbleX,
            bubbleRect: bubbleRect,
            textOriginInRow: textOriginInRow,
            cachedHeight: cachedHeight,
            cachedWidth: width,
            laidOutExpanded: state.isExpanded)
    }

    // MARK: - Collapse helpers

    static func canCollapse(layout: Layout, theme: TranscriptTheme) -> Bool {
        layout.textLayout.lines.count
            >= theme.userBubbleCollapseThreshold + theme.userBubbleMinHiddenLines
    }

    static func shouldCollapse(layout: Layout, state: State, theme: TranscriptTheme) -> Bool {
        canCollapse(layout: layout, theme: theme) && !state.isExpanded
    }

    // MARK: - Render

    @MainActor
    static func render(
        _ layout: Layout,
        state: State,
        theme: TranscriptTheme,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        guard !layout.textLayout.lines.isEmpty else { return }
        let bubbleRect = layout.bubbleRect
        let path = CGPath(
            roundedRect: bubbleRect,
            cornerWidth: theme.bubbleCornerRadius,
            cornerHeight: theme.bubbleCornerRadius,
            transform: nil)

        // 1) Bubble fill —— 永远满 alpha,不被 mask 影响。
        ctx.saveGState()
        ctx.setFillColor(theme.bubbleFillColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // 2) 文字画在 transparency layer,独立做 alpha mask。
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let sel: NSRange? = (state.selection.location != NSNotFound && state.selection.length > 0)
            ? state.selection : nil
        layout.textLayout.draw(origin: layout.textOriginInRow, selection: sel, in: ctx)

        if shouldCollapse(layout: layout, state: state, theme: theme) {
            applyTextFadeMask(in: ctx, bubbleRect: bubbleRect, theme: theme)
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 3) Chevron 不进 clip 不进 transparency layer。
        if canCollapse(layout: layout, theme: theme) {
            drawChevron(in: ctx, layout: layout, state: state, theme: theme)
        }
    }

    /// Destination-in alpha mask:fade 底部,只遮文字不遮气泡色。
    @MainActor
    private static func applyTextFadeMask(
        in ctx: CGContext,
        bubbleRect: CGRect,
        theme: TranscriptTheme
    ) {
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

    @MainActor
    private static func drawChevron(
        in ctx: CGContext,
        layout: Layout,
        state: State,
        theme: TranscriptTheme
    ) {
        let rect = chevronDrawRect(bubbleRect: layout.bubbleRect, theme: theme)
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let halfW = rect.width / 2
        let halfH = rect.height / 2 * 0.7

        let path = CGMutablePath()
        if state.isExpanded {
            // ⌃
            path.move(to: CGPoint(x: mid.x - halfW, y: mid.y + halfH / 2))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y - halfH / 2))
            path.addLine(to: CGPoint(x: mid.x + halfW, y: mid.y + halfH / 2))
        } else {
            // ⌄
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

    private static func chevronDrawRect(bubbleRect: CGRect, theme: TranscriptTheme) -> CGRect {
        CGRect(
            x: bubbleRect.maxX - theme.chevronInset - theme.chevronSize,
            y: bubbleRect.maxY - theme.chevronInset - theme.chevronSize,
            width: theme.chevronSize,
            height: theme.chevronSize)
    }

    private static func chevronHitRect(bubbleRect: CGRect, theme: TranscriptTheme) -> CGRect {
        let glyph = chevronDrawRect(bubbleRect: bubbleRect, theme: theme)
        let expand = (theme.chevronHitSize - theme.chevronSize) / 2
        return glyph.insetBy(dx: -expand, dy: -expand)
    }

    // MARK: - Interactions

    @MainActor
    static func interactions(
        _ layout: Layout,
        state: State
    ) -> [Interaction<Self>] {
        guard canCollapse(layout: layout, theme: .default) else { return [] }
        // theme: chevron 仅看 bubbleRect + chevronInset/Size;默认 theme 足够
        // 算命中区 —— render 里用的是真实 theme,命中与绘制的几何函数共享
        // chevronHitRect 与 chevronDrawRect。这里我们使用 `TranscriptTheme.default`
        // 的 chevron 常量(与绘制路径一致)。
        let theme = TranscriptTheme.default
        let rect = chevronHitRect(bubbleRect: layout.bubbleRect, theme: theme)
        var newState = state
        newState.isExpanded.toggle()
        newState.selection = NSRange(location: NSNotFound, length: 0)
        return [
            .toggleState(rect: rect, newState: newState, cursor: .pointingHand)
        ]
    }

    // MARK: - Selectables

    @MainActor
    static func selectables(
        _ layout: Layout,
        state: State
    ) -> [SelectableSlot] {
        guard !layout.textLayout.lines.isEmpty else { return [] }
        // 折叠态把 region 高度截到可见区 —— drag 起点不落到隐藏行。
        let theme = TranscriptTheme.default
        let visibleHeight: CGFloat
        if shouldCollapse(layout: layout, state: state, theme: theme) {
            visibleHeight = max(1, layout.bubbleRect.height - 2 * theme.bubbleVerticalPadding)
        } else {
            visibleHeight = max(layout.textLayout.totalHeight, 1)
        }
        return [SelectableSlot(
            ordering: SlotOrdering(fragmentOrdinal: 0, subIndex: 0),
            mode: .flow,
            frameInRow: CGRect(
                x: layout.textOriginInRow.x,
                y: layout.textOriginInRow.y,
                width: max(layout.textLayout.measuredWidth, 1),
                height: visibleHeight),
            layout: layout.textLayout,
            selectionKey: AnyHashable(0))]
    }

    @MainActor
    static func applySelection(
        key: AnyHashable,
        range: NSRange,
        to state: State
    ) -> State {
        var out = state
        out.selection = range
        return out
    }

    @MainActor
    static func clearingSelection(_ state: State) -> State {
        var out = state
        out.selection = NSRange(location: NSNotFound, length: 0)
        return out
    }

    @MainActor
    static func selectedFragments(
        _ layout: Layout,
        state: State
    ) -> [CopyFragment] {
        guard state.selection.location != NSNotFound, state.selection.length > 0 else {
            return []
        }
        let sub = layout.textLayout.attributed.attributedSubstring(from: state.selection)
        return [CopyFragment(
            ordering: SlotOrdering(fragmentOrdinal: 0, subIndex: 0),
            text: sub.string)]
    }
}
