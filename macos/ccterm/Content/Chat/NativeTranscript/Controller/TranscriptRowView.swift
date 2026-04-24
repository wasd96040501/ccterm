import AppKit
import QuartzCore

/// Transcript 每一行的容器 view。绘制走 `ComponentRow.callbacks.render` —
/// 不再认识具体 row 子类。Theme 通过 weak controller 读取(避免每次 set(row:)
/// 都强制传 theme)。
class TranscriptRowView: NSTableRowView, CALayerDelegate {
    private(set) var row: ComponentRow?
    weak var controller: TranscriptController?

    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.delegate = self
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func set(row: ComponentRow?) {
        self.row = row
        layer?.setNeedsDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {}

    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let row else { return }
        let theme = TranscriptTheme(markdown: controller?.theme ?? .default)
        let contentW = row.cachedSize.width > 0 ? row.cachedSize.width : bounds.width
        let inset = max(0, (bounds.width - contentW) / 2)
        let contentBounds = CGRect(x: 0, y: 0, width: contentW, height: bounds.height)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.saveGState()
            if inset > 0 {
                ctx.translateBy(x: inset, y: 0)
            }
            row.callbacks.render(row, ctx, contentBounds, theme)
            ctx.restoreGState()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.setNeedsDisplay()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}
