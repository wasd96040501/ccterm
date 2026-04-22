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

    /// mouseDown 记点用于 mouseUp 判 drag 距离——若 drag < 阈值且命中 link，
    /// mouseUp 视为点击并打开 URL（对齐 Telegram `TextView.mouseUp`）。
    private var mouseDownPoint: CGPoint?

    /// 不调 super —— NSTableView 默认会处理行选中 / highlight，我们禁掉。
    /// 把 document 坐标转成自身 bounds 空间（tableView = documentView，
    /// frame 原点就是 document 原点），直接喂 selectionController。
    ///
    /// 点击粒度：对齐 Telegram `TextView.mouseUp`
    /// - clickCount == 2 → 选中 word
    /// - clickCount == 3 → 选中 paragraph
    /// - clickCount == 1 → 开始 drag 选中（字符粒度）；mouseUp 时若未发生 drag
    ///   且命中 link，打开 URL
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let selection = controller?.selectionController else { return }
        window?.makeFirstResponder(selection)

        switch event.clickCount {
        case 3:
            mouseDownPoint = nil
            selection.selectParagraph(at: point)
        case 2:
            mouseDownPoint = nil
            selection.selectWord(at: point)
        default:
            mouseDownPoint = point
            selection.beginDrag(at: point)
        }
        controller?.redrawAllVisibleRows()
    }

    override func mouseDragged(with event: NSEvent) {
        // 双/三击后的 drag 暂不扩段；只有 clickCount == 1 才 extend。
        // Telegram 的双击 drag by-word 目前未实现，后续需要再补。
        guard event.clickCount == 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        controller?.selectionController.updateDrag(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 无 drag（鼠标位移 < 3pt） + 命中 link → 打开并清 selection。
        if let start = mouseDownPoint {
            mouseDownPoint = nil
            let dx = point.x - start.x
            let dy = point.y - start.y
            let draggedSquared = dx * dx + dy * dy
            if draggedSquared <= 9,
               let url = controller?.linkURL(atDocumentPoint: point) {
                controller?.selectionController.clear()
                controller?.redrawAllVisibleRows()
                NSWorkspace.shared.open(url)
                return
            }
        }
        controller?.selectionController.endDrag(at: point)
    }

    // MARK: - I-beam cursor on hover

    /// 对齐 Telegram `TextView.checkCursor`：鼠标进入可选中文字区域 → iBeam，
    /// 其它 → arrow。通过 `cursorUpdate` 和显式 tracking area 的 `mouseMoved`
    /// / `mouseEntered` / `mouseExited` 共同驱动。
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = cursorTrackingArea {
            removeTrackingArea(old)
        }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil)
        addTrackingArea(ta)
        cursorTrackingArea = ta
    }

    override func cursorUpdate(with event: NSEvent) {
        checkCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        checkCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        checkCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func checkCursor(at documentPoint: CGPoint) {
        if controller?.linkURL(atDocumentPoint: documentPoint) != nil {
            NSCursor.pointingHand.set()
        } else if isPointOverSelectableText(documentPoint) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func isPointOverSelectableText(_ documentPoint: CGPoint) -> Bool {
        guard let controller else { return false }
        let rowIdx = row(at: documentPoint)
        guard rowIdx >= 0, rowIdx < controller.rows.count else { return false }
        guard let selectable = controller.rows[rowIdx] as? TextSelectable else {
            return false
        }
        let rowRect = rect(ofRow: rowIdx)
        let pointInRow = CGPoint(
            x: documentPoint.x - rowRect.origin.x,
            y: documentPoint.y - rowRect.origin.y)
        return selectable.selectableRegions.contains { $0.frameInRow.contains(pointInRow) }
    }
}
