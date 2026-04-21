import AppKit

/// Transcript 的 NSTableView 子类。对齐 Telegram `TGFlipableTableView`：
/// - flipped：y 向下递增，row 0 在最上
/// - layer-backed + `.never` redraw：live scroll / resize 零重画
/// - 单 column 铺满宽度，drawing 全走 rowView
/// - `postsFrameChangedNotifications`：用于 controller 捕获宽度变化并重排
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

        // 对齐 Telegram 的 TGFlipableTableView：
        // - `autoresizesSubviews = false` 关掉 AppKit 自动 resize
        // - 不 add column，`.noColumnAutoresizing` 让 NSTableView 不再以 column 宽度
        //   为 ground truth 去反推 frame.width——这正是上个版本 setFrameSize 死循环的根源。
        // rowViewForRow 仍会对每行被调到，不依赖 column。
        autoresizesSubviews = false
        columnAutoresizingStyle = .noColumnAutoresizing
        if #available(macOS 11.0, *) {
            style = .fullWidth
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - oldWidth) > 0.5 {
            appLog(.debug, "TranscriptTableView",
                "setFrameSize width \(Int(oldWidth))→\(Int(newSize.width))")
            controller?.tableWidthChanged(newSize.width)
        }
    }
}
