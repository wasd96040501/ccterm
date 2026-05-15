import AgentSDK
import AppKit
import CoreText
import QuartzCore

/// 连续 tool_use 聚合 row —— 不论 tool kind,所有 assistant 消息只要 content
/// 全是 tool_use 就归这里。Header(title + chevron + shimmer)+ 展开态内嵌
/// N 条 child(per-tool dispatch 到 ``GroupChildRenderer``:Read 是 header-style
/// 文字行,其它是虚线占位框)。
///
/// `isActive = (entryIndex == entryCount - 1)` —— group 是 `entries.last` 即
/// 视作运行中。
///
/// 整 group(header + 所有 child)= **一个 NSTableView row**。toggle 展开
/// 走 `applyState` 的 `relayouted` 快路径,无 row insert/delete。子项**不**
/// 实现 `TranscriptComponent`,而是 ``GroupChildRenderer`` plug-in。
enum GroupComponent: TranscriptComponent {
    static let tag = "Group"

    // MARK: - Input / Content / Layout / State

    struct Input: @unchecked Sendable {
        let stableId: StableId
        /// 折叠态 active title —— 最后一条 tool 的进行时短语。
        let activeBriefTitle: String
        /// 展开态 active title —— 聚合进行时短语(`Reading 3 files · …`)。
        let activeAggregatedTitle: String
        /// 完成态 title —— 聚合过去时短语(`Read 3 files · …`)。
        let completedTitle: String
        let isActive: Bool
        /// 全部 tool_use,按 group item 顺序展平(单个 item 可能包含多个 tool_use)。
        let toolUses: [ToolUseEntry]

        struct ToolUseEntry: @unchecked Sendable {
            let toolUseId: String
            let tool: ToolUse
        }
    }

    struct Content: @unchecked Sendable {
        let isActive: Bool
        /// 三套 title 各自 prepare 一次 —— 切换不重 CT measure。
        let activeBrief: TitleMeasure
        let activeAggregated: TitleMeasure
        let completed: TitleMeasure
        /// per-child parsed payload,顺序 = ``Input.toolUses``。
        let children: [ChildEntry]

        struct ChildEntry: @unchecked Sendable {
            let toolUseId: String
            let content: GroupChildContent
        }

        struct TitleMeasure: @unchecked Sendable {
            let text: String
            let width: CGFloat
            let ascent: CGFloat
            let descent: CGFloat
        }

        /// 当前 (isActive, isExpanded) 下应展示的标题串 + 几何 —— layout 阶段
        /// 选用,render 阶段 sideCar 直接读。
        func pickTitle(isExpanded: Bool) -> TitleMeasure {
            switch (isActive, isExpanded) {
            case (true, false):  return activeBrief
            case (true, true):   return activeAggregated
            case (false, _):     return completed
            }
        }
    }

    struct Layout: HasHeight, Sendable {
        let content: Content
        /// 当前选中的 title,layout 时锁定。
        let titleText: String
        let titleRect: CGRect
        let chevronRect: CGRect
        let hitRect: CGRect
        /// 展开时各 child 的 frame;折叠时 [].
        let childFrames: [GroupChildFrame]
        let cachedHeight: CGFloat
        let cachedWidth: CGFloat
        let laidOutExpanded: Bool
    }

    struct State: Sendable {
        var isExpanded: Bool = false
        /// 留给未来富化 child 用 —— 第一步 Read 不带 substate。key = toolUseId,
        /// sparse map 默认空,绝大多数 child 不写入。
        var childStates: [String: ChildSubstate] = [:]

        static let `default` = State()
    }

    /// child 的 row-local state(Read 第一步无字段;Edit diff 展开等 future case
    /// 在这里加 enum case)。
    enum ChildSubstate: Sendable {
        case none
    }

    typealias SideCar = GroupSideCar

    // MARK: - Inputs

    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int,
        entryCount: Int
    ) -> [IdentifiedInput<Input>] {
        guard case .group(let group) = entry else { return [] }
        let isActive = (entryIndex == entryCount - 1)
        let stableId = StableId(entryId: group.id, locator: .whole)

        // 把整 group 的所有 tool_use 按 (item, blockOrder) 顺序展平。`tool.id` 在
        // generated 类型里是 `String?` —— 缺失场景(jsonl fixture 偶发) 用 toolUseId
        // 当兜底,group children 的相对顺序仍由展平顺序决定。
        var toolUses: [Input.ToolUseEntry] = []
        for item in group.items {
            for tool in item.toolUses {
                toolUses.append(.init(toolUseId: tool.id ?? "", tool: tool))
            }
        }

        return [IdentifiedInput(
            stableId: stableId,
            entryIndex: entryIndex,
            blockIndex: 0,
            input: Input(
                stableId: stableId,
                activeBriefTitle: group.activeTitle,
                activeAggregatedTitle: group.expandedActiveTitle,
                completedTitle: group.completedTitle,
                isActive: isActive,
                toolUses: toolUses))]
    }

    // MARK: - Prepare

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        let active = measure(input.activeBriefTitle, theme: theme)
        let activeAgg = measure(input.activeAggregatedTitle, theme: theme)
        let completed = measure(input.completedTitle, theme: theme)
        let children = input.toolUses.map { entry in
            Content.ChildEntry(
                toolUseId: entry.toolUseId,
                content: GroupChildDispatch.parse(entry.tool, theme: theme))
        }
        return Content(
            isActive: input.isActive,
            activeBrief: active,
            activeAggregated: activeAgg,
            completed: completed,
            children: children)
    }

    nonisolated private static func measure(
        _ text: String, theme: TranscriptTheme
    ) -> Content.TitleMeasure {
        let attrs: [NSAttributedString.Key: Any] = [.font: theme.groupTitleFont]
        let str = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Content.TitleMeasure(
            text: text,
            width: CGFloat(width),
            ascent: ascent,
            descent: descent)
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.activeBriefTitle)
        h.combine(input.activeAggregatedTitle)
        h.combine(input.completedTitle)
        h.combine(input.isActive)
        h.combine(input.toolUses.count)
        for entry in input.toolUses {
            h.combine(entry.toolUseId)
            h.combine(GroupChildDispatch.contentHash(entry.tool, theme: theme))
        }
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    nonisolated static func initialState(for input: Input) -> State {
        .default
    }

    // MARK: - Layout

    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        geometry(content: content, theme: theme, width: width, state: state)
    }

    /// 快路径:width + content 未变,只 `isExpanded` 翻转 → 重选 title +
    /// 重算 childFrames + cachedHeight。
    nonisolated static func relayouted(
        _ layout: Layout,
        theme: TranscriptTheme,
        state: State
    ) -> Layout? {
        guard layout.laidOutExpanded != state.isExpanded else { return layout }
        return geometry(
            content: layout.content,
            theme: theme,
            width: layout.cachedWidth,
            state: state)
    }

    nonisolated private static func geometry(
        content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        let hPad = theme.rowHorizontalPadding
        let headerTop = theme.rowVerticalPadding
        let headerH = theme.groupHeaderHeight
        let rowContentWidth = max(0, width - 2 * hPad)
        let chevronSize = theme.groupChevronDrawSize
        let gap = theme.groupChevronGap

        let title = content.pickTitle(isExpanded: state.isExpanded)

        // Title 占据文字宽度,但给 chevron + gap 留空间。
        let reservedForChevron = chevronSize + gap
        let titleMaxWidth = max(0, rowContentWidth - reservedForChevron)
        let titleWidth = min(title.width, titleMaxWidth)

        let titleH = title.ascent + title.descent
        let headerMidY = headerTop + headerH / 2
        let titleRect = CGRect(
            x: hPad,
            y: headerMidY - titleH / 2,
            width: titleWidth,
            height: titleH)

        // Chevron 视觉居中补偿 —— 同原实现。
        let font = theme.groupTitleFont
        let visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)
        let chevronRect = CGRect(
            x: titleRect.maxX + gap,
            y: headerMidY - chevronSize / 2 + visualCompensation,
            width: chevronSize,
            height: chevronSize)

        let hitPad = theme.groupHitPadding
        let hitMinX = max(hPad, titleRect.minX - hitPad)
        let hitMaxX = min(hPad + rowContentWidth, chevronRect.maxX + hitPad)
        let hitRect = CGRect(
            x: hitMinX,
            y: headerTop,
            width: max(0, hitMaxX - hitMinX),
            height: headerH)

        // Children:gestalt 接近性下,header → first child 间距 = child ↔ child
        // 间距 = 4pt(``groupChildSpacing``)。最后一个 child 后接 row 自身的
        // bottom rowVerticalPadding,继而和下条 entry 的 top padding 加和成 ≥ 24pt
        // 视觉分隔(l0)。
        var childFrames: [GroupChildFrame] = []
        var totalHeight = headerTop + headerH
        if state.isExpanded && !content.children.isEmpty {
            var y = totalHeight + theme.groupChildSpacing
            for child in content.children {
                let frame = GroupChildDispatch.layout(
                    child.content,
                    x: hPad,
                    y: y,
                    width: rowContentWidth,
                    theme: theme)
                let h = GroupChildDispatch.height(frame)
                childFrames.append(frame)
                y += h + theme.groupChildSpacing
            }
            // 移除最后一次多加的 spacing(child 后面紧接 row vertical padding)。
            y -= theme.groupChildSpacing
            totalHeight = y
        }
        totalHeight += theme.rowVerticalPadding

        return Layout(
            content: content,
            titleText: title.text,
            titleRect: titleRect,
            chevronRect: chevronRect,
            hitRect: hitRect,
            childFrames: childFrames,
            cachedHeight: totalHeight,
            cachedWidth: width,
            laidOutExpanded: state.isExpanded)
    }

    // MARK: - Render

    @MainActor
    static func render(
        _ layout: Layout,
        state: State,
        theme: TranscriptTheme,
        sideCar: GroupSideCar,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        // CGContext 路径只画 children;header(title / chevron / shimmer)由
        // SideCar 的 CALayer 完成。
        for (frame, child) in zip(layout.childFrames, layout.content.children) {
            GroupChildDispatch.draw(child.content, frame: frame, theme: theme, in: ctx)
        }

        sideCar.sync(
            title: layout.titleText,
            titleRect: layout.titleRect,
            chevronRect: layout.chevronRect,
            isActive: layout.content.isActive,
            isExpanded: state.isExpanded,
            theme: theme)
    }

    // MARK: - SideCar factory

    @MainActor
    static func makeSideCar(for content: Content) -> GroupSideCar {
        GroupSideCar()
    }

    // MARK: - Interactions

    @MainActor
    static func interactions(
        _ layout: Layout,
        state: State
    ) -> [Interaction<Self>] {
        let hit = layout.hitRect
        return [
            .custom(
                rect: hit,
                cursor: .pointingHand,
                handler: { ctx in
                    // 把 row-height 平滑插值 + chevron 旋转 + title fade 全部
                    // 包在同一个 NSAnimationContext 里 —— NSTableView 在
                    // `noteHeightOfRows` 时按当前 group 的 duration 走 builtin
                    // CABasicAnimation(高度从旧 cachedHeight 平滑到新值)。
                    NSAnimationContext.runAnimationGroup { animCtx in
                        animCtx.duration = ctx.theme.groupExpandDuration
                        animCtx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        var newState = ctx.currentState()
                        newState.isExpanded.toggle()
                        ctx.applyState(newState, animated: true)
                    }
                }),
            .hover(
                rect: hit,
                cursor: .pointingHand,
                onEnter: { ctx in ctx.sideCar().setHovered(true, theme: ctx.theme) },
                onExit:  { ctx in ctx.sideCar().setHovered(false, theme: ctx.theme) }),
        ]
    }
}
