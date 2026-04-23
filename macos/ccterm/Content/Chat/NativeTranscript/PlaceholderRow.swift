import AppKit
import CoreText

/// 工具调用 / thinking / group 的占位 row。
/// 灰色虚线边框 + 中心 label 文本，固定高度约 36pt。
///
/// Fragment 化实现：`.rect(stroke dashed)` + `.line(label)`。
final class PlaceholderRow: TranscriptRow, FragmentRow {
    let label: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 宽度无关：init / applyLayout 时 CT 排好，`fragments(width:)` 只拼几何。
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

    /// Adopts a precomputed `PlaceholderPrepared`. Layout is width-independent
    /// and trivial, so the caller may follow up with `applyLayout(_:)`
    /// directly from prepare output without re-typesetting on main.
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
    /// off-main by `TranscriptPrepare.layoutPlaceholder`. 高度宽度无关，
    /// 直接采纳；fragments 留到首次 `makeSize(width:)` 惰性构造（cachedWidth
    /// 保持 0 强制触发），`cachedHeight` 先吃 layout 的值保证 heightOfRow
    /// 在 fragments 构造前就有正确值。
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

    // MARK: - FragmentRow

    func fragments(width: CGFloat) -> FragmentLayout {
        if labelLine == nil { buildLabelLine() }

        let rect = CGRect(
            x: theme.placeholderHorizontalInset,
            y: theme.rowVerticalPadding + theme.placeholderVerticalInset,
            width: max(0, width - 2 * theme.placeholderHorizontalInset),
            height: theme.placeholderHeight - 2 * theme.placeholderVerticalInset)

        var out: [Fragment] = []
        out.append(.rect(RectFragment(
            frame: rect,
            style: .stroke(
                NSColor.tertiaryLabelColor,
                lineWidth: 1,
                dash: theme.placeholderLineDashPattern,
                cornerRadius: theme.placeholderCornerRadius))))

        if let line = labelLine {
            // Vertically center the label on the rect's midline.
            // `TranscriptRowView` 的 `draw(_:in:)` 会把 textMatrix flip，
            // 这里的 origin.y 是 row-local top，baseline = origin.y + ascent。
            let baselineY = rect.midY + (labelAscent - labelDescent) / 2
            out.append(.line(LineFragment(
                line: line,
                origin: CGPoint(x: rect.minX + 12, y: baselineY - labelAscent),
                ascent: labelAscent,
                descent: labelDescent,
                width: labelWidth)))
        }

        let totalHeight = theme.placeholderHeight + 2 * theme.rowVerticalPadding
        return FragmentLayout(fragments: out, height: totalHeight)
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
