import AppKit

/// NSClipView 子类，仅改变两件事：
/// - flipped：配合 TranscriptTableView 的坐标系
/// - layer-backed + `.never` redraw：滚动时 GPU composite，不触发重画
final class TranscriptClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}
