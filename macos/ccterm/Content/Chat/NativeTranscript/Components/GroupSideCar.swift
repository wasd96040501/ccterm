import AppKit
import QuartzCore

/// Group row 的 CA 侧 —— title / shimmer / chevron 三个 CALayer,挂
/// `rowView.layer`(AppKit 管 contentsScale,不用手管)。
///
/// 层级(下→上):
/// - `titleLayer` (CATextLayer):标题底色文字
/// - `shimmerLayer` (CAGradientLayer, mask = `shimmerMaskLayer`):active 态可见,
///   mask 把 gradient 裁到 title 字形,光带只扫文字
/// - `chevronLayer` (CAShapeLayer):2 段 `>` vector,`transform.rotation.z` 旋转
///
/// ## 居中列 offset
///
/// sublayer frame 用 "内容列局部坐标"(layout 算)。挂在全宽 `rowView.layer` 上,
/// `sync` 时把 frame.origin.x 加 `currentXOffset`(framework 每 render 前通过
/// `applyColumnXOffset` 注入)让 CA 路径和 CGContext 路径看到同一内容列起点。
///
/// ## 动画驱动
///
/// - rotation: `sync` 内部读 presentation 值 → toggle model → 在 disableActions
///   transaction **外** 显式 `CABasicAnimation`(避免被禁)
/// - title fade(active+collapsed ↔ active+expanded): `sync` 检测 string 变化时
///   先 `add(CATransition.fade)` 再改 string —— 必须在 disableActions transaction
///   外部
/// - shimmer: active 态启动,inactive 停止
@MainActor
final class GroupSideCar: RowSideCar {
    private let titleLayer = CATextLayer()
    private let shimmerLayer = CAGradientLayer()
    private let shimmerMaskLayer = CATextLayer()
    private let chevronLayer = CAShapeLayer()

    private var currentTitle: String = ""
    private var currentTitleRect: CGRect = .zero
    private var currentChevronRect: CGRect = .zero
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
        shimmerMaskLayer.foregroundColor = NSColor.white.cgColor

        shimmerLayer.startPoint = CGPoint(x: -1, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.opacity = 0
        shimmerLayer.mask = shimmerMaskLayer

        chevronLayer.fillColor = nil
        chevronLayer.lineCap = .round
        chevronLayer.lineJoin = .round
        chevronLayer.lineWidth = 1.4
        chevronLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
    }

    nonisolated deinit {}

    // MARK: - RowSideCar lifecycle

    func sideCarDidMount(in rowLayer: CALayer) {
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
        titleLayer.removeAllAnimations()
        titleLayer.removeFromSuperlayer()
        shimmerLayer.removeFromSuperlayer()
        chevronLayer.removeFromSuperlayer()
        isShimmerAnimating = false
    }

    func applyColumnXOffset(_ xOffset: CGFloat) {
        guard xOffset != currentXOffset else { return }
        currentXOffset = xOffset
        currentTitleRect = .zero
        currentChevronRect = .zero
    }

    // MARK: - Full sync

    func sync(
        title: String,
        titleRect: CGRect,
        chevronRect: CGRect,
        isActive active: Bool,
        isExpanded expanded: Bool,
        theme: TranscriptTheme
    ) {
        // Rotation pre-capture(在 model 改之前读 presentation 值)。
        let modelRotBefore = (chevronLayer.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        let presRotBefore = chevronLayer.presentation()?
            .value(forKeyPath: "transform.rotation.z") as? CGFloat
        let rotationFrom: CGFloat? = {
            guard expanded != isExpanded else { return nil }
            if let pres = presRotBefore { return pres }
            return modelRotBefore
        }()

        // Title 字符串变化 → 加 fade transition。在 disableActions transaction
        // 外部触发(transition 是 layer-level animation,会被 disableActions 屏蔽)。
        let titleStringChanged = (title != currentTitle && !currentTitle.isEmpty)

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

        let hl = theme.groupShimmerHighlight.cgColor
        let clear = theme.groupShimmerHighlight.withAlphaComponent(0).cgColor
        shimmerLayer.colors = [clear, hl, clear]
        shimmerLayer.locations = [0, 0.5, 1]

        if active != isActive {
            shimmerLayer.opacity = active ? 1 : 0
            isActive = active
            if active {
                startShimmerAnimation(theme: theme)
            } else {
                stopShimmerAnimation()
            }
        } else if active && !isShimmerAnimating {
            shimmerLayer.opacity = 1
            startShimmerAnimation(theme: theme)
        }

        if let from = rotationFrom {
            let target: CGFloat = expanded ? (.pi / 2) : 0
            chevronLayer.setValue(target, forKeyPath: "transform.rotation.z")
            pendingRotation = (from: from, to: target)
            isExpanded = expanded
        }

        chevronLayer.opacity = Float(isHovered
            ? theme.groupChevronHoverAlpha
            : theme.groupChevronIdleAlpha)

        CATransaction.commit()

        // 显式动画在 disableActions 外部 add ——
        if let r = pendingRotation {
            pendingRotation = nil
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.duration = theme.groupChevronRotateDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.fromValue = r.from
            anim.toValue = r.to
            chevronLayer.add(anim, forKey: "rotate")
        }

        // Title fade ——(active+collapsed ↔ active+expanded 切换时聚合短语会变,
        // 直接换 string 突兀;用 CATransition 做平滑)。
        if titleStringChanged {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = theme.groupTitleFadeDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            titleLayer.add(transition, forKey: "titleFade")
            shimmerMaskLayer.add(transition, forKey: "titleFade")
        }
    }

    /// Hover 进入 / 离开 —— 不重 layout,只动画 chevron alpha + title 颜色。
    func setHovered(_ hovered: Bool, theme: TranscriptTheme) {
        guard hovered != isHovered else { return }
        isHovered = hovered

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
        titleLayer.add(titleAnim, forKey: "hoverColor")
    }

    private func titleColorForCurrentState(theme: TranscriptTheme) -> NSColor {
        isHovered ? NSColor.labelColor : theme.groupTitleColor
    }

    private func chevronColorForCurrentState(theme: TranscriptTheme) -> NSColor {
        isHovered ? NSColor.labelColor : theme.groupTitleColor
    }

    // MARK: - Chevron path

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
