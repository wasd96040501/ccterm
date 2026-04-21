import AppKit

/// Transcript 顶层 NSScrollView：
/// - responsive scrolling：让 AppKit 在滚动时可以拼 layer bitmap 而非同步 drawRect
/// - layer-backed + `.never` redraw：滚动 0 个 draw 调用
/// - 自带 `TranscriptClipView` + `TranscriptTableView` + `TranscriptController`
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

        // Pad the scrollable content so the first / last row don't kiss the
        // viewport edges. Combined with `rowVerticalPadding` = 8 per row,
        // first row's visible top gap = 12 + 8 = 20pt (matches legacy VStack
        // `.padding(.vertical, 20)`).
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        let clip = TranscriptClipView(frame: frameRect)
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
        appLog(.debug, "TranscriptScrollView",
            "tile clip=\(Int(target)) table=\(Int(tableView.frame.width))")
        // `contentView.bounds.width` can briefly be <= 0 during scroller
        // accounting (e.g. scroller eats 17pt out of a 0-width scroll view).
        // Propagating that to setFrameSize produces "Invalid view geometry".
        guard target > 0.5 else { return }
        if abs(tableView.frame.width - target) > 0.5 {
            tableView.setFrameSize(NSSize(width: target, height: tableView.frame.height))
        }
    }
}
