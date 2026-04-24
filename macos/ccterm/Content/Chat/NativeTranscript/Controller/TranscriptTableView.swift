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

        // Routing 分两类语义,**不要**让 clickCount 无差别穿透:
        //   1) Hit region(chevron / code header 等 `.custom` / `.invoke` 按钮语义)
        //      —— 所有 clickCount 都退化成"单击",mouseUp 走 performHit。否则
        //      快速连点会被识别成双击(clickCount=2)→ selectWord 分支把
        //      mouseDownPoint 擦成 nil,mouseUp 的 `clickCount == 1` guard
        //      直接 return,点击完全消失。按钮不该被双击语义劫持。
        //   2) 文本 slot —— 按 clickCount 分派 drag / word / paragraph。
        if controller?.cursorOverHit(atDocumentPoint: point) != nil {
            mouseDownPoint = point
            selection.beginDrag(at: point)
            controller?.redrawAllVisibleRows()
            return
        }

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
        let point = convert(event.locationInWindow, from: nil)
        // clickCount != 1 时 mouseDown 的 case 2/3 已经处理了文本选中语义,
        // 这里只看 mouseDownPoint 是否被设置 —— 设了就意味着 mouseDown 走的是
        // "单击 / hit-region" 分支(mouseDown 里 hit region 早退也设了 point),
        // mouseUp 应该尝试 performHit,不该被 clickCount guard 吃掉。
        guard event.clickCount == 1 || mouseDownPoint != nil else { return }
        // 无 drag（鼠标位移 < 3pt）时分派：row hit region > link > drag-select end。
        if let start = mouseDownPoint {
            mouseDownPoint = nil
            let dx = point.x - start.x
            let dy = point.y - start.y
            let draggedSquared = dx * dx + dy * dy
            appLog(.debug, "TranscriptTableView",
                "mouseUp start=\(start) up=\(point) dragSq=\(draggedSquared) passThreshold=\(draggedSquared <= 9)")
            if draggedSquared <= 9 {
                // Row hit region 优先：chevron / code block header 等都由 row
                // 自报的 `hitRegions` 统一承接，perform 闭包里自己处理 clear
                // selection / redraw。URL 叠在 chevron 上时应 toggle 而非打开
                // URL，这个优先级由 row 自己的 region 排在前面保证。
                if controller?.performHit(atDocumentPoint: point) == true {
                    return
                }
                if let url = controller?.linkURL(atDocumentPoint: point) {
                    controller?.selectionController.clear()
                    controller?.redrawAllVisibleRows()
                    NSWorkspace.shared.open(url)
                    return
                }
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
        let p = convert(event.locationInWindow, from: nil)
        checkCursor(at: p)
        controller?.updateHover(atDocumentPoint: p)
    }

    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        checkCursor(at: p)
        controller?.updateHover(atDocumentPoint: p)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        checkCursor(at: p)
        controller?.updateHover(atDocumentPoint: p)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        controller?.updateHover(atDocumentPoint: nil)
    }

    private func checkCursor(at documentPoint: CGPoint) {
        // Row hit region > link > selectable text > default。
        // hit region 的 cursor 由 row 自报（通常是 pointingHand）；link 也是
        // pointingHand。点击分派在 mouseUp。
        if let cursor = controller?.cursorOverHit(atDocumentPoint: documentPoint) {
            cursor.set()
        } else if controller?.linkURL(atDocumentPoint: documentPoint) != nil {
            NSCursor.pointingHand.set()
        } else if isPointOverSelectableText(documentPoint) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func isPointOverSelectableText(_ documentPoint: CGPoint) -> Bool {
        guard let controller else { return false }
        guard let ctx = controller.rowLocalContext(at: documentPoint) else { return false }
        let row = controller.rows[ctx.rowIndex]
        let pointInRow = ctx.toRowLocal(documentPoint)
        let slots = row.callbacks.selectables(row)
        return slots.contains { $0.frameInRow.contains(pointInRow) }
    }
}
