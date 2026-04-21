import AppKit

/// Transcript 每一行的容器 view。
/// - layer-backed + `layerContentsRedrawPolicy = .never`：scroll / resize 只 GPU composite，
///   不触发重画；只有 `set(item:)` 时显式 `needsDisplay = true` 才重绘。
/// - flipped：和 `TranscriptTableView` 对齐，坐标原点左上。
/// - `draw(_:)`：委派回 `item.draw(in:bounds:)`。
class TranscriptRowView: NSTableRowView {
    private(set) var item: TranscriptRowItem?

    // `required` so `cls.init(frame:)` works via the `TranscriptRowView.Type`
    // returned from `TranscriptRowItem.viewClass()`.
    required override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 绑定新 item 到 view。每次都标脏——即便是同一个 item 对象,其内部 layout
    /// 可能因为 `tableWidthChanged` 而已被刷新过。`layerContentsRedrawPolicy = .never`
    /// 保证多次 setNeedsDisplay 只合并成一次实际 draw,不会多绘。
    func set(item: TranscriptRowItem?) {
        self.item = item
        if let item {
            appLog(.debug, "TranscriptRowView",
                "set item=\(String(describing: type(of: item))) itemW=\(Int(item.cachedWidth)) rowW=\(Int(frame.width))")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let ctx = NSGraphicsContext.current?.cgContext else { return }
        item.draw(in: ctx, bounds: bounds)
    }

    // 默认 NSTableRowView 会画选中 / hover 高亮——transcript 纯只读，全关掉。
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}
