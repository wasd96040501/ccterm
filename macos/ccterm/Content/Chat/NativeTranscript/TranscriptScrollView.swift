import AppKit

/// Transcript 顶层 NSScrollView：
/// - responsive scrolling：让 AppKit 在滚动时可以拼 layer bitmap 而非同步 drawRect
/// - layer-backed + `.never` redraw：滚动 0 个 draw 调用
/// - 自带 `FlippedClipView` + `TranscriptTableView` + `TranscriptController`
///
/// 负宽度保护：AppKit 会在初装 / 滚动条计算期临时给 0 或负宽度。我们这里
/// + `TranscriptTableView.setFrameSize` 两层都 clamp 到 ≥ 0。
final class TranscriptScrollView: NSScrollView {
    let controller: TranscriptController
    private let tableView: TranscriptTableView

    override init(frame frameRect: NSRect) {
        let table = TranscriptTableView(frame: frameRect)
        let ctrl = TranscriptController(tableView: table)
        self.tableView = table
        self.controller = ctrl

        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .never
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        autohidesScrollers = true

        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        let clip = FlippedClipView(frame: frameRect)
        contentView = clip
        documentView = table

        table.controller = ctrl
        table.dataSource = ctrl
        table.delegate = ctrl
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override func tile() {
        super.tile()
        let target = contentView.bounds.width
        // contentView.bounds.width 在 scroller 还没定好前可能 <= 0（比如 0 width
        // 减去 17pt scroller 变成 -17）——propagate 下去会触发 AppKit 警告。
        guard target > 0.5 else { return }
        if abs(tableView.frame.width - target) > 0.5 {
            tableView.setFrameSize(NSSize(width: target, height: tableView.frame.height))
        }
    }

    // MARK: - Live resize two-phase

    /// 对齐 Telegram `TableView.swift:684-697`：live 期间只排可见行，结束时
    /// 一次性补跑 off-screen 行 + 恢复 scroll anchor。TranscriptController
    /// 负责具体策略；这里只搬钩子。
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        controller.beginLiveResize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller.endLiveResize(finalWidth: contentView.bounds.width)
    }
}

// MARK: - ClipView

/// NSClipView 子类，仅改变两件事：
/// - flipped：配合 `TranscriptTableView` 的坐标系
/// - layer-backed + `.never` redraw：滚动时 GPU composite，不触发重画
private final class FlippedClipView: NSClipView {
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
