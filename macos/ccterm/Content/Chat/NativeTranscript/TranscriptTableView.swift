import AppKit

/// Transcript 的 NSTableView 子类。
///
/// - flipped：y 向下递增，row 0 在最上
/// - layer-backed + `.never` redraw：live scroll / resize 零重画
/// - 单 column 铺满宽度，绘制全走 rowView
/// - 鼠标事件走 `TranscriptSelectionController`——拖选、清选、Cmd-C
final class TranscriptTableView: NSTableView {
    weak var controller: TranscriptController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .never
        backgroundColor = .clear

        headerView = nil
        gridStyleMask = []
        intercellSpacing = NSSize(width: 0, height: 0)
        selectionHighlightStyle = .none
        allowsColumnSelection = false
        allowsMultipleSelection = false
        allowsEmptySelection = true
        allowsTypeSelect = false
        usesAlternatingRowBackgroundColors = false
        rowSizeStyle = .custom

        // 关掉 AppKit 自动 resize 链 + 不 add column，避免 setFrameSize 死循环。
        autoresizesSubviews = false
        columnAutoresizingStyle = .noColumnAutoresizing
        if #available(macOS 11.0, *) {
            style = .fullWidth
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Frame sizing with negative-width guard

    /// AppKit 在 scrollView 初装 / 滚动条计算期可能临时用 0 或负值（如
    /// `0 - 17 (scroller width)`）调 setFrameSize，会触发
    /// `Invalid view geometry: width is negative` 警告。
    /// 这里直接 clamp 到 ≥ 0 并早退——值已经被 clip 出去的情况由 tile()
    /// / scrollView 负责之后再回流。
    override func setFrameSize(_ newSize: NSSize) {
        let safeSize = NSSize(
            width: max(0, newSize.width),
            height: max(0, newSize.height))
        let oldWidth = frame.width
        super.setFrameSize(safeSize)
        if safeSize.width > 0, abs(safeSize.width - oldWidth) > 0.5 {
            controller?.tableWidthChanged(safeSize.width)
        }
    }

    // MARK: - Mouse selection

    override var acceptsFirstResponder: Bool { true }

    /// 不调 super —— NSTableView 默认会处理行选中 / highlight，我们禁掉。
    /// 把 document 坐标转成自身 bounds 空间（tableView = documentView，
    /// frame 原点就是 document 原点），直接喂 selectionController。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let selection = controller?.selectionController {
            window?.makeFirstResponder(selection)
            selection.beginDrag(at: point)
            controller?.redrawAllVisibleRows()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.selectionController.updateDrag(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.selectionController.endDrag(at: point)
    }
}
