import AppKit
import CoreText

/// 工具调用 / thinking / group 的占位 row。
/// 灰色虚线边框 + 中心 label 文本，固定高度。
final class PlaceholderRow: TranscriptRow {
    let label: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 宽度无关：init / applyLayout 时 CT 排好，draw 路径只读。
    private var labelLine: CTLine?
    private var labelAscent: CGFloat = 0
    private var labelDescent: CGFloat = 0
    private var labelWidth: CGFloat = 0

    init(label: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.label = label
        self.theme = theme
        self.stable = stable
        super.init()
        buildLabelLine()
    }

    /// Adopts a precomputed `PlaceholderPrepared`. Layout 是宽度无关的，
    /// 调用方紧跟着 `applyLayout(_:)` 喂 prepare 阶段的 CT 结果就能
    /// 完全避开 main-thread 排版。
    init(prepared: PlaceholderPrepared, theme: TranscriptTheme) {
        self.label = prepared.label
        self.theme = theme
        self.stable = prepared.stable
        super.init()
        buildLabelLine()
    }

    /// 显式标注：Swift 6 子类 deinit 不自动继承父类 nonisolated 属性，
    /// 需要逐层声明才能真正跳过 executor-hop。见 `TranscriptRow.deinit`。
    nonisolated deinit { }

    /// Adopts a precomputed `PlaceholderLayoutData` — CTLine already built
    /// off-main by `TranscriptPrepare.layoutPlaceholder`.
    func applyLayout(_ layout: PlaceholderLayoutData) {
        self.labelLine = layout.labelLine
        self.labelAscent = layout.labelAscent
        self.labelDescent = layout.labelDescent
        self.labelWidth = CGFloat(CTLineGetTypographicBounds(
            layout.labelLine, nil, nil, nil))
        self.cachedHeight = layout.cachedHeight
    }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(label)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - Layout

    /// 高度宽度无关（固定 `placeholderHeight`）；这里只记 `cachedWidth`，
    /// 不动 `cachedHeight`（由 `applyLayout` 或 `init` 设好）。
    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width
        if cachedHeight == 0 {
            cachedHeight = theme.placeholderHeight + 2 * theme.rowVerticalPadding
        }
    }

    // MARK: - Draw

    override func draw(in ctx: CGContext, bounds: CGRect) {
        if labelLine == nil { buildLabelLine() }

        let rect = CGRect(
            x: theme.placeholderHorizontalInset,
            y: theme.rowVerticalPadding + theme.placeholderVerticalInset,
            width: max(0, cachedWidth - 2 * theme.placeholderHorizontalInset),
            height: theme.placeholderHeight - 2 * theme.placeholderVerticalInset)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: theme.placeholderLineDashPattern)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: theme.placeholderCornerRadius,
            cornerHeight: theme.placeholderCornerRadius,
            transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        if let line = labelLine {
            // Vertically center the label on the rect's midline.
            // Context is flipped; textMatrix flip maps glyphs correctly.
            let baselineY = rect.midY + (labelAscent - labelDescent) / 2
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: rect.minX + 12,
                y: baselineY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Private

    private func buildLabelLine() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.placeholderTextFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        labelLine = line
        labelAscent = ascent
        labelDescent = descent
        labelWidth = width
    }
}
