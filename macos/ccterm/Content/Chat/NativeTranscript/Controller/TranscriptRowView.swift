import AppKit
import QuartzCore

/// Transcript 每一行的容器 view。绘制走 `ComponentRow.callbacks.render` —
/// 不再认识具体 row 子类。Theme 通过 weak controller 读取(避免每次 set(row:)
/// 都强制传 theme)。
///
/// ## 居中列坐标
///
/// rowView 是全窗口宽 —— 内容列(`theme.maxContentWidth`)居中留白。painter
/// 一侧靠 `ctx.translateBy(x: inset)` 把 CGContext 平移到内容列;SideCar CA
/// 一侧挂在 rowView.layer 上,不走 translate,所以 framework 在 draw 前通过
/// `sideCar.applyColumnXOffset(inset)` 告知当前 inset,SideCar 自己在 sync 时
/// 把 sublayer.frame.x 加上。
///
/// `rowView.layer` 是 AppKit 管的主 layer,`contentsScale` 自动跟 backingScale —
/// SideCar 挂到这里,CATextLayer 等子层不用手管 scale。
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
        // Transition SideCar lifecycle:
        //   - 旧 row 存在且 (新 row 换了 stableId 或新 row 为 nil)  → unmount 旧
        //   - 新 row 存在且 (旧 row 为 nil 或旧 row stableId 不同)  → mount 新
        // 同 stableId 的 carry-over 不动 SideCar。
        let oldRow = self.row
        let oldId = oldRow?.stableId
        let newId = row?.stableId

        if let oldSide = oldRow?.sideCar, oldId != newId, let rowLayer = layer {
            oldSide.sideCarWillUnmount(from: rowLayer)
        }
        self.row = row
        if let newSide = row?.sideCar, oldId != newId, let rowLayer = layer {
            newSide.sideCarDidMount(in: rowLayer)
        }
        layer?.setNeedsDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {}

    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let row else { return }
        let theme = TranscriptTheme(markdown: controller?.theme ?? .default)
        let contentW = row.cachedSize.width > 0 ? row.cachedSize.width : bounds.width
        let inset = max(0, (bounds.width - contentW) / 2)
        let contentBounds = CGRect(x: 0, y: 0, width: contentW, height: bounds.height)
        // 告知 SideCar 当前 inset —— SideCar sublayer 挂 rowView.layer,不受
        // 下面 translate 影响,必须自己加 offset 到 frame.x。
        row.sideCar.applyColumnXOffset(inset)
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

    override func prepareForReuse() {
        super.prepareForReuse()
        // Row view 回 reuse 池前主动 unmount 当前 SideCar —— 放掉 CA 动画 /
        // 移走 sublayer。next set(row:) 会再 mount。
        if let old = row?.sideCar, let rowLayer = layer {
            old.sideCarWillUnmount(from: rowLayer)
        }
        self.row = nil
    }
}
