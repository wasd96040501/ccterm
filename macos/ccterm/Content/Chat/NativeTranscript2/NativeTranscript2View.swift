import AppKit
import SwiftUI

/// SwiftUI entry point. Wraps `Transcript2ScrollView` (containing a
/// `NSTableView` driven by `Transcript2Coordinator`) and forwards `[Block]`
/// updates from SwiftUI to the coordinator.
struct NativeTranscript2View: NSViewRepresentable {
    let blocks: [Block]

    func makeCoordinator() -> Transcript2Coordinator { Transcript2Coordinator() }

    func makeNSView(context: Context) -> Transcript2ScrollView {
        let scroll = Transcript2ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .never
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        scroll.contentView = Transcript2ClipView()

        let table = Transcript2TableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        context.coordinator.tableView = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ nsView: Transcript2ScrollView, context: Context) {
        context.coordinator.setBlocks(blocks)
    }

    static func dismantleNSView(_ nsView: Transcript2ScrollView,
                                coordinator: Transcript2Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

// MARK: - Preview

/// Generated once at module load — keeps `Block.id`s and `NSImage` instance
/// stable across Preview re-renders so the diff sees no churn.
private let previewBlocks: [Block] = {
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
    let demoImage = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
        ?? NSImage(size: NSSize(width: 200, height: 120))
    return [
        Block(id: UUID(), kind: .heading("Refactor plan")),
        Block(id: UUID(), kind: .paragraph(
            "Replace the existing NativeTranscript module with a smaller, "
            + "Core Text–based renderer.")),
        Block(id: UUID(), kind: .heading("Layouts so far")),
        Block(id: UUID(), kind: .paragraph(
            "TextLayout handles headings and paragraphs. ImageLayout handles "
            + "raster / vector images. Both report their own height and draw "
            + "themselves through the RowLayout enum.")),
        Block(id: UUID(), kind: .image(demoImage)),
        Block(id: UUID(), kind: .paragraph(
            "Adding a new block kind means: extend Block.Kind, add a XxxLayout "
            + "primitive, add a case to RowLayout, add a switch arm in "
            + "Transcript2Coordinator.makeRowItem.")),
    ]
}()

#Preview("NativeTranscript2 — heading + paragraph + image") {
    NativeTranscript2View(blocks: previewBlocks)
        .frame(width: 600, height: 600)
}
