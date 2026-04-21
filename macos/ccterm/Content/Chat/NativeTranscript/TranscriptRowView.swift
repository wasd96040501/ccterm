import AppKit
import QuartzCore

/// Transcript 每一行的容器 view，走 Telegram `TableRowView` 的 CALayerDelegate 路线：
/// - `wantsLayer = true` + `layerContentsRedrawPolicy = .never`：滚动期 0 draw，GPU composite
/// - `layer.delegate = self` + 实现 `CALayerDelegate.draw(_:in:)`：CA 在每次
///   `layer.setNeedsDisplay()` 后会**先清 backing store**，再调 delegate.draw。
///   这是 Telegram 能干净地复用 rowView 而不出现“旧 row 像素残留”的关键——
///   NSView 的 `draw(_:)` 路径下 `.never` 模式是否清 backing 没有明确保证。
/// - `override func draw(_ dirtyRect:)` 留空：阻断 NSView 的默认 draw 路径,
///   所有绘制都通过 CALayerDelegate 方法走。
class TranscriptRowView: NSTableRowView, CALayerDelegate {
    private(set) var row: TranscriptRow?

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // AppKit 对 layer-backed NSView 通常会把 layer.delegate 自动设为 self，
        // 但在某些 reuse 路径下会被重置。显式赋值，防御。
        layer?.delegate = self
        // 明确透明底，让 CA 在 composite 阶段有一致的背景基准。
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 绑定新 row 到 view。用 `layer.setNeedsDisplay()`——CA 会先清 backing
    /// 再调 `draw(_:in:)`，天然消除新旧 row 像素叠加。
    func set(row: TranscriptRow?) {
        self.row = row
        layer?.setNeedsDisplay()
    }

    /// 空 override，阻断 NSView 的默认绘制路径。绘制走 CALayerDelegate。
    override func draw(_ dirtyRect: NSRect) {}

    /// CALayerDelegate.draw(_:in:)。
    /// NSView 的 `isFlipped = true` 使 AppKit 同时把 `layer.isGeometryFlipped`
    /// 也设上，CA 传进来的 `ctx` 已经是 y 向下（原点左上）——直接喂给 `row.draw`
    /// 不需要再做坐标翻转。文字层面由 `ctx.textMatrix = (1, -1)` 翻 glyph 即可
    /// （跟 Telegram 的做法一致）。
    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let row else { return }
        row.draw(in: ctx, bounds: bounds)
    }

    // NSTableRowView 默认还会画 selection / hover / separator——transcript 纯只读，全关。
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}
