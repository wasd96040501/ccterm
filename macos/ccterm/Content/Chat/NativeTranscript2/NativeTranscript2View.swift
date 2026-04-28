import AppKit
import SwiftUI

/// SwiftUI entry point. Wraps `Transcript2ScrollView` (containing a
/// `NSTableView` driven by `Transcript2Coordinator`).
///
/// The view takes a caller-owned `Transcript2Controller` — there is no
/// `[Block]` `State` parameter. Callers mutate transcript content
/// imperatively via `controller.apply(.insert / .remove / .update)` for
/// incremental changes, or `controller.loadInitial(_:)` for the cold-load
/// path. SwiftUI's role is reduced to mounting the AppKit view and wiring
/// the existing coordinator into it; `updateNSView` is a no-op.
struct NativeTranscript2View: NSViewRepresentable {
    let controller: Transcript2Controller

    func makeCoordinator() -> Transcript2Coordinator { controller.coordinator }

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

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        coordinator.tableView = table
        table.coordinator = coordinator
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ nsView: Transcript2ScrollView, context: Context) {
        // No-op. Content is pushed via `controller.apply(_:)`, not pulled
        // from a SwiftUI snapshot.
    }

    static func dismantleNSView(_ nsView: Transcript2ScrollView,
                                coordinator: Transcript2Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

// MARK: - Preview

/// Generated once at module load — keeps `Block.id`s and `NSImage` instance
/// stable across Preview re-renders.
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
            + "Transcript2Coordinator.makeLayout.")),
    ]
}()

private struct PreviewWrapper: View {
    @State private var controller = Transcript2Controller()

    var body: some View {
        NativeTranscript2View(controller: controller)
            .task {
                if controller.blockCount == 0 {
                    controller.loadInitial(previewBlocks)
                }
            }
    }
}

#Preview("NativeTranscript2 — heading + paragraph + image") {
    PreviewWrapper()
        .frame(width: 600, height: 600)
}
