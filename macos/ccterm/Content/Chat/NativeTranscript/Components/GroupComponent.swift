import AgentSDK
import AppKit
import CoreText
import QuartzCore

/// 连续同类 tool_use 聚合 row —— 标题(active/completed 两态)+ 贴在标题后
/// 居中对齐的 chevron + 运行中 shimmer 光带(仅扫过文字字形)+ 展开态
/// 内嵌 N 条 placeholder-style 子行。
///
/// `isActive = (entryIndex == entryCount - 1)` —— group 是 `entries.last`
/// 即视作运行中。
///
/// 标题 / chevron / shimmer 全部走 `GroupSideCar` 的 CALayer + CABasicAnimation,
/// CGContext 只画展开态的 N 条虚线框。
enum GroupComponent: TranscriptComponent {
    static let tag = "Group"

    struct Input: Sendable {
        let stableId: StableId
        let activeTitle: String
        let completedTitle: String
        let childCount: Int
        let isActive: Bool
    }

    struct Content: @unchecked Sendable {
        let isActive: Bool
        let childCount: Int
        /// 当前 `isActive` 下显示的那条 title —— prepare 时二选一 cache 下来,
        /// render 时 CATextLayer.string 直接用。
        let title: String
        let titleWidth: CGFloat
        let titleAscent: CGFloat
        let titleDescent: CGFloat
    }

    struct Layout: HasHeight, Sendable {
        let content: Content
        /// 标题 bounding box(CATextLayer frame),row-local。
        let titleRect: CGRect
        /// Chevron bounding box(CAShapeLayer frame),贴 titleRect.maxX 右侧居中对齐。
        let chevronRect: CGRect
        /// 点击 + hover 命中区 —— title + chevron 的合并 + padding 外扩。
        let hitRect: CGRect
        /// 展开时 N 个子行 rect;折叠时 []。x/width 和 tool placeholder 同形(全宽)。
        let childRects: [CGRect]
        let cachedHeight: CGFloat
        let cachedWidth: CGFloat
        /// 本 layout 算于哪个 `isExpanded` 值 —— `relayouted` 快路径用来判断。
        let laidOutExpanded: Bool
    }

    struct State: Sendable {
        var isExpanded: Bool = false

        static let `default` = State()
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
        return [IdentifiedInput(
            stableId: stableId,
            entryIndex: entryIndex,
            blockIndex: 0,
            input: Input(
                stableId: stableId,
                activeTitle: group.activeTitle,
                completedTitle: group.completedTitle,
                childCount: group.items.count,
                isActive: isActive))]
    }

    // MARK: - Prepare

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        let title = input.isActive ? input.activeTitle : input.completedTitle
        let attrs: [NSAttributedString.Key: Any] = [.font: theme.groupTitleFont]
        let str = NSAttributedString(string: title, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Content(
            isActive: input.isActive,
            childCount: input.childCount,
            title: title,
            titleWidth: CGFloat(width),
            titleAscent: ascent,
            titleDescent: descent)
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.activeTitle)
        h.combine(input.completedTitle)
        h.combine(input.childCount)
        h.combine(input.isActive)
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

    /// 快路径:width + content 未变,仅 `isExpanded` 翻转 → 只重算 childRects
    /// 和 cachedHeight。
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

        // Title 占据文字宽度,但给 chevron + gap 留空间。
        let reservedForChevron = chevronSize + gap
        let titleMaxWidth = max(0, rowContentWidth - reservedForChevron)
        let titleWidth = min(content.titleWidth, titleMaxWidth)

        let titleH = content.titleAscent + content.titleDescent
        let headerMidY = headerTop + headerH / 2
        let titleRect = CGRect(
            x: hPad,
            y: headerMidY - titleH / 2,
            width: titleWidth,
            height: titleH)

        // Chevron 垂直视觉居中:文字的几何 midY(ascent/descent 中点)高于
        // 视觉中心(baseline + x-height/2 附近),chevron 按几何 midY 对齐会
        // 看起来偏上。加 `(capHeight - xHeight) / 2` 补偿把 chevron 下移到
        // 字形视觉中心。12pt semibold 约 1pt。
        let font = theme.groupTitleFont
        let visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)
        let chevronRect = CGRect(
            x: titleRect.maxX + gap,
            y: headerMidY - chevronSize / 2 + visualCompensation,
            width: chevronSize,
            height: chevronSize)

        // Hit rect = title + chevron 的合并 + 外扩 padding,高度撑满 header。
        let hitPad = theme.groupHitPadding
        let hitMinX = max(hPad, titleRect.minX - hitPad)
        let hitMaxX = min(hPad + rowContentWidth, chevronRect.maxX + hitPad)
        let hitRect = CGRect(
            x: hitMinX,
            y: headerTop,
            width: max(0, hitMaxX - hitMinX),
            height: headerH)

        // Child placeholders:和 tool placeholder 同形(全宽,对齐 rowHorizontalPadding)。
        var childRects: [CGRect] = []
        var totalHeight = headerTop + headerH
        if state.isExpanded && content.childCount > 0 {
            let childH = theme.groupChildRowHeight
            let spacing = theme.groupChildRowSpacing
            let childX = hPad
            let childW = rowContentWidth
            var y = totalHeight + theme.groupChildrenTopSpacing
            for _ in 0..<content.childCount {
                childRects.append(CGRect(x: childX, y: y, width: childW, height: childH))
                y += childH + spacing
            }
            y -= spacing
            y += theme.groupChildrenBottomPadding
            totalHeight = y
        }
        totalHeight += theme.rowVerticalPadding

        return Layout(
            content: content,
            titleRect: titleRect,
            chevronRect: chevronRect,
            hitRect: hitRect,
            childRects: childRects,
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
        drawChildPlaceholders(layout: layout, theme: theme, in: ctx)

        // 同步 SideCar(title CATextLayer + shimmer + chevron)。每次 render 都调,
        // 让 liveAppend 翻 isActive / 外观切换 dark-light / 宽度变化等都自动
        // 反映到 CA 图层。CATransaction 在 SideCar 内部处理,禁掉隐式动画。
        sideCar.sync(
            title: layout.content.title,
            titleRect: layout.titleRect,
            chevronRect: layout.chevronRect,
            isActive: layout.content.isActive,
            isExpanded: state.isExpanded,
            theme: theme)
    }

    @MainActor
    private static func drawChildPlaceholders(
        layout: Layout, theme: TranscriptTheme, in ctx: CGContext
    ) {
        guard !layout.childRects.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: theme.placeholderLineDashPattern)
        for r in layout.childRects {
            let path = CGPath(
                roundedRect: r,
                cornerWidth: theme.placeholderCornerRadius,
                cornerHeight: theme.placeholderCornerRadius,
                transform: nil)
            ctx.addPath(path)
        }
        ctx.strokePath()
        ctx.restoreGState()
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
            // 单一驱动:handler 只 toggle state,动画在 render → sync 里按
            // 新 state 与 sideCar.isExpanded 的差异决定是否起旋转动画。
            // 避免 handler 与 render 两条路径都操作 CALayer 导致 rapid-click 打架。
            .custom(
                rect: hit,
                cursor: .pointingHand,
                handler: { ctx in
                    var newState = ctx.currentState()
                    newState.isExpanded.toggle()
                    ctx.applyState(newState)
                }),
            .hover(
                rect: hit,
                cursor: .pointingHand,
                onEnter: { ctx in ctx.sideCar().setHovered(true, theme: ctx.theme) },
                onExit:  { ctx in ctx.sideCar().setHovered(false, theme: ctx.theme) }),
        ]
    }
}

// MARK: - GroupSideCar

/// Group row 的 CA 侧 —— title / shimmer / chevron 三个 CALayer,全挂
/// `rowView.layer`(AppKit 管 contentsScale,不用手动管 backing scale)。
///
/// 层级(从下到上):
/// - `titleLayer` (CATextLayer):标题底色文字,常驻
/// - `shimmerLayer` (CAGradientLayer, mask = `shimmerMaskLayer`):仅 active 态可见,
///   mask 把 gradient 裁到 title 字形内,所以光带只扫文字
/// - `chevronLayer` (CAShapeLayer):2 段 `>` vector path,strokeColor 切色,
///   `transform.rotation.z` 旋转,vector 自动按父 layer contentsScale 抗锯齿
///
/// ## 居中列 offset
///
/// sublayer 的 `titleRect` / `chevronRect` 都是"内容列局部坐标"(由 layout 算),
/// 但它们挂在全宽 rowView.layer 上,sync 时把 frame.origin.x 统一加 `currentXOffset`
/// (framework 每 render 前通过 `applyColumnXOffset` 注入)让 CA 路径和 CGContext
/// 路径看到同一内容列起点。
///
/// 所有 model value 写入都包 `CATransaction.setDisableActions(true)`,避免
/// 隐式动画和显式动画打架(表现为:快速点击卡在展开态不回弹)。
@MainActor
final class GroupSideCar: RowSideCar {
    private let titleLayer = CATextLayer()
    private let shimmerLayer = CAGradientLayer()
    private let shimmerMaskLayer = CATextLayer()
    /// 2 段 `>` vector path。strokeColor 决定颜色,`transform.rotation.z`
    /// 驱动旋转。vector,不需要 bitmap rasterize,挂 rowView.layer 自动沿用
    /// AppKit 管的 contentsScale。
    private let chevronLayer = CAShapeLayer()

    private var currentTitle: String = ""
    private var currentTitleRect: CGRect = .zero
    private var currentChevronRect: CGRect = .zero
    /// Framework 通过 `applyColumnXOffset(_:)` 注入,sync 时加到 sublayer frame.x。
    private var currentXOffset: CGFloat = 0
    private var isActive = false
    private var isExpanded = false
    private var isHovered = false
    private var isShimmerAnimating = false
    /// Sync 内部暂存 —— CATransaction 提交后再在外部 add 显式旋转动画。
    private var pendingRotation: (from: CGFloat, to: CGFloat)?

    init() {
        titleLayer.alignmentMode = .left
        titleLayer.truncationMode = .end
        titleLayer.isWrapped = false

        shimmerMaskLayer.alignmentMode = .left
        shimmerMaskLayer.truncationMode = .end
        shimmerMaskLayer.isWrapped = false
        // Mask 只取 alpha 通道,foregroundColor 用不透明白色最简单。
        shimmerMaskLayer.foregroundColor = NSColor.white.cgColor

        shimmerLayer.startPoint = CGPoint(x: -1, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.opacity = 0
        shimmerLayer.mask = shimmerMaskLayer

        chevronLayer.fillColor = nil
        chevronLayer.lineCap = .round
        chevronLayer.lineJoin = .round
        chevronLayer.lineWidth = 1.4
        // frame resize 不做隐式动画 —— 居中列重定位时避免 chevron 飘移。
        chevronLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
    }

    nonisolated deinit {}

    // MARK: - RowSideCar lifecycle

    func sideCarDidMount(in rowLayer: CALayer) {
        // CATextLayer / CAShapeLayer 的 contentsScale 不继承父 layer,默认 1 —
        // Retina 必糊。rowLayer 是 NSView 管的主 layer,AppKit 已经把
        // contentsScale 设成 backingScaleFactor(2 / 3),这里直接跟随。
        let scale = rowLayer.contentsScale > 0 ? rowLayer.contentsScale : 2
        titleLayer.contentsScale = scale
        shimmerMaskLayer.contentsScale = scale
        chevronLayer.contentsScale = scale
        rowLayer.addSublayer(titleLayer)
        rowLayer.addSublayer(shimmerLayer)
        rowLayer.addSublayer(chevronLayer)
    }

    func sideCarWillUnmount(from rowLayer: CALayer) {
        shimmerLayer.removeAllAnimations()
        chevronLayer.removeAllAnimations()
        titleLayer.removeFromSuperlayer()
        shimmerLayer.removeFromSuperlayer()
        chevronLayer.removeFromSuperlayer()
        isShimmerAnimating = false
    }

    func applyColumnXOffset(_ xOffset: CGFloat) {
        // 值相等不动 sublayer frame —— 避免每帧 render 都重写 frame 造成无谓工作。
        // 下一次 sync 如果 currentXOffset 变了,会自动 invalidate currentTitleRect /
        // currentChevronRect 比对路径,触发 frame 重写。
        guard xOffset != currentXOffset else { return }
        currentXOffset = xOffset
        // Offset 变化 → 所有 sublayer frame.x 都要重算 —— 通过重置 currentXxxRect
        // 触发 sync 里的"frame 变化"分支。
        currentTitleRect = .zero
        currentChevronRect = .zero
    }

    // MARK: - Full sync(render 时一次性)

    /// 单一入口 —— render 把 "一行 row 当前应呈现的视觉状态" 一次性同步给 CA 层。
    /// 所有 model value 写在一个 CATransaction 禁隐式动画;显式动画(旋转 / hover
    /// fade)由外部通过 `setExpanded(animated:)` / `setHovered(_:)` 单独触发。
    func sync(
        title: String,
        titleRect: CGRect,
        chevronRect: CGRect,
        isActive active: Bool,
        isExpanded expanded: Bool,
        theme: TranscriptTheme
    ) {
        // Rotation pre-capture:在 setValue 把 model 改掉之前,先读 presentation。
        // 这是显式动画 `fromValue`,也是 sync 为什么是 rotation 的**唯一驱动**
        // 的关键 —— handler 只 toggle state,所有 CALayer 写入都在这里按
        // (expected ≠ current) 差异执行。
        let modelRotBefore = (chevronLayer.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        let presRotBefore = chevronLayer.presentation()?
            .value(forKeyPath: "transform.rotation.z") as? CGFloat
        let rotationFrom: CGFloat? = {
            guard expanded != isExpanded else { return nil }
            if let pres = presRotBefore { return pres }
            return modelRotBefore
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let font = theme.groupTitleFont
        let fontSize = font.pointSize

        if title != currentTitle {
            titleLayer.string = title
            shimmerMaskLayer.string = title
            currentTitle = title
        }
        titleLayer.font = font
        titleLayer.fontSize = fontSize
        titleLayer.foregroundColor = titleColorForCurrentState(theme: theme).cgColor

        shimmerMaskLayer.font = font
        shimmerMaskLayer.fontSize = fontSize

        if titleRect != currentTitleRect {
            // rowView 坐标 = 内容列局部坐标 + currentXOffset。
            let titleFrame = titleRect.offsetBy(dx: currentXOffset, dy: 0)
            titleLayer.frame = titleFrame
            shimmerLayer.frame = titleFrame
            shimmerMaskLayer.frame = CGRect(origin: .zero, size: titleRect.size)
            currentTitleRect = titleRect
        }

        if chevronRect != currentChevronRect {
            chevronLayer.frame = chevronRect.offsetBy(dx: currentXOffset, dy: 0)
            chevronLayer.path = Self.chevronPath(in: CGRect(origin: .zero, size: chevronRect.size))
            currentChevronRect = chevronRect
        }
        chevronLayer.strokeColor = chevronColorForCurrentState(theme: theme).cgColor

        // Shimmer colors always set —— 切深浅色需要刷新 cgColor(NSColor 的 name
        // 动态色 cgColor 不随 appearance 自更新,得每次重新 resolve)。
        let hl = theme.groupShimmerHighlight.cgColor
        let clear = theme.groupShimmerHighlight.withAlphaComponent(0).cgColor
        shimmerLayer.colors = [clear, hl, clear]
        shimmerLayer.locations = [0, 0.5, 1]

        // Active → opacity 1 + 启动动画;inactive → opacity 0 + 停动画。
        if active != isActive {
            shimmerLayer.opacity = active ? 1 : 0
            isActive = active
            if active {
                startShimmerAnimation(theme: theme)
            } else {
                stopShimmerAnimation()
            }
        } else if active && !isShimmerAnimating {
            // 挂载后第一次 sync,active 已经是 true,但动画还没起。
            shimmerLayer.opacity = 1
            startShimmerAnimation(theme: theme)
        }

        // 旋转 —— sync 是唯一驱动。model value 在 disableActions 里写,避免隐式动画。
        if let from = rotationFrom {
            let target: CGFloat = expanded ? (.pi / 2) : 0
            chevronLayer.setValue(target, forKeyPath: "transform.rotation.z")
            // 显式动画在 CATransaction 提交之后 add —— 不受 disableActions 影响。
            // 先记录下来,本次 commit 之后再加。
            pendingRotation = (from: from, to: target)
            isExpanded = expanded
        }

        // Chevron alpha 跟随 hover 态。
        chevronLayer.opacity = Float(isHovered
            ? theme.groupChevronHoverAlpha
            : theme.groupChevronIdleAlpha)

        CATransaction.commit()

        // 在 disableActions transaction **外部** add 显式 rotation anim ——
        // 虽然 CAAnimation 的 add 不受 disableActions 影响,但在外部更清晰,
        // 也方便未来按需 disable 掉整个 sync 的 action。
        if let r = pendingRotation {
            pendingRotation = nil
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.duration = theme.groupChevronRotateDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.fromValue = r.from
            anim.toValue = r.to
            chevronLayer.add(anim, forKey: "rotate")
        }
    }

    /// Render 外部的 hover 事件 —— 只改本地状态,真正的 CALayer 属性同步由
    /// 之后的 render → sync 或本方法内的 explicit animation 负责。title 颜色
    /// 和 chevron alpha 都在 hover 切换时动画过渡。
    func setHovered(_ hovered: Bool, theme: TranscriptTheme) {
        guard hovered != isHovered else { return }
        isHovered = hovered

        // Chevron alpha 动画 ——(fade 0.15s)。
        let chevronTarget: Float = Float(hovered
            ? theme.groupChevronHoverAlpha
            : theme.groupChevronIdleAlpha)
        let chevronFrom = chevronLayer.presentation()?.opacity ?? chevronLayer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevronLayer.opacity = chevronTarget
        CATransaction.commit()
        let chevronAnim = CABasicAnimation(keyPath: "opacity")
        chevronAnim.duration = theme.groupChevronFadeDuration
        chevronAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        chevronAnim.fromValue = chevronFrom
        chevronAnim.toValue = chevronTarget
        chevronLayer.add(chevronAnim, forKey: "fade")

        // Title 颜色 ——(secondary ↔ primary)CA 层上靠 foregroundColor
        // transition 动画,fade 平滑切换。
        let titleTargetColor = titleColorForCurrentState(theme: theme).cgColor
        let titleFromColor = titleLayer.presentation()?.foregroundColor
            ?? titleLayer.foregroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.foregroundColor = titleTargetColor
        CATransaction.commit()
        let titleAnim = CABasicAnimation(keyPath: "foregroundColor")
        titleAnim.duration = theme.groupChevronFadeDuration
        titleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        titleAnim.fromValue = titleFromColor
        titleAnim.toValue = titleTargetColor
        titleLayer.add(titleAnim, forKey: "titleFade")
    }

    /// Hover 态:title 用 primary labelColor;idle:secondary。
    private func titleColorForCurrentState(theme: TranscriptTheme) -> NSColor {
        isHovered ? NSColor.labelColor : theme.groupTitleColor
    }

    /// Chevron 底色 —— 跟随 title 的 hover 态同步(primary / secondary)。
    /// alpha 差异(idle / hover)由 `chevronLayer.opacity` 另行控制。
    private func chevronColorForCurrentState(theme: TranscriptTheme) -> NSColor {
        isHovered ? NSColor.labelColor : theme.groupTitleColor
    }

    // MARK: - Chevron path
    //
    // Base: `>` 右指(折叠态 = 常规 disclosure 起点)。展开态 sync 给
    // `transform.rotation.z = π/2`,顺时针 90° 变下指 `v`。
    //
    // 形状参数按 SF Symbol `chevron.right` 比例调的(宽:高 ≈ 0.56,lineWidth
    // 对应 semibold 级 ≈ 1.4pt at 8pt glyph):
    // - halfW = size × 0.22(从中心到右尖水平距离)
    // - halfH = size × 0.4 (从中心到上下端垂直距离)
    // - lineCap / lineJoin = .round(init 里设一次)

    private static func chevronPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let halfW = rect.width * 0.22
        let halfH = rect.height * 0.4
        path.move(to: CGPoint(x: mid.x - halfW, y: mid.y - halfH))
        path.addLine(to: CGPoint(x: mid.x + halfW, y: mid.y))
        path.addLine(to: CGPoint(x: mid.x - halfW, y: mid.y + halfH))
        return path
    }

    // MARK: - Shimmer animation

    private func startShimmerAnimation(theme: TranscriptTheme) {
        if isShimmerAnimating { return }
        isShimmerAnimating = true

        let band = theme.groupShimmerBandRatio
        // 光带从左侧完全不可见(startPoint 在左外)扫到右侧完全不可见
        // (endPoint 在右外)。一个 band 宽度是 (endPoint.x - startPoint.x)。
        let startAnim = CABasicAnimation(keyPath: "startPoint")
        startAnim.fromValue = NSValue(point: CGPoint(x: -band, y: 0.5))
        startAnim.toValue = NSValue(point: CGPoint(x: 1.0, y: 0.5))
        let endAnim = CABasicAnimation(keyPath: "endPoint")
        endAnim.fromValue = NSValue(point: CGPoint(x: 0.0, y: 0.5))
        endAnim.toValue = NSValue(point: CGPoint(x: 1.0 + band, y: 0.5))

        let group = CAAnimationGroup()
        group.animations = [startAnim, endAnim]
        group.duration = theme.groupShimmerDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        shimmerLayer.add(group, forKey: "shimmer")
    }

    private func stopShimmerAnimation() {
        shimmerLayer.removeAnimation(forKey: "shimmer")
        isShimmerAnimating = false
    }

}
