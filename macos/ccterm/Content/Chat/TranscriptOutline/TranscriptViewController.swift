import AppKit

/// The outline transcript's view controller: builds the
/// `NSScrollView` (host) + `TranscriptOutlineView` tree, binds itself as
/// the outline's dataSource / delegate, and drives data from the
/// injected `TranscriptStore`. A thin coordinator — all state (tree +
/// layout cache) lives in the store; this VC only maps outline callbacks
/// onto store queries and mounts cells (SPEC §6.2).
///
/// Geometry model (SPEC §5): the outline is a **full-width, frame-based
/// documentView** — the native contract for `NSTableView`-family views
/// (width tracks the clip, height comes from the table's own tile, so
/// user-driven animated expansion grows the document correctly). The
/// centered 460–780 content column lives *inside* each row: widths and
/// origins all come from `TranscriptOutlineMetrics`, the disclosure
/// triangle is repositioned into the column by
/// `TranscriptOutlineView.frameOfOutlineCell(atRow:)`, and the cell clips
/// drawing to the column so no layout can paint outside it.
@MainActor
final class TranscriptViewController: NSViewController {
    private let store: TranscriptStore

    private let scrollView = NSScrollView()
    private let outlineView = TranscriptOutlineView()

    init(store: TranscriptStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View tree

    override func loadView() {
        let host = NSView()

        // Full-width outline — frame-based documentView (no constraints,
        // no translates=false: a table-family documentView manages its
        // own frame via tile and the clip's autoresize; constraining it
        // is outside its design contract and breaks the height growth
        // path of animated expansion). Native triangle placement is
        // handled by `TranscriptOutlineView`; all per-level indentation
        // is expressed by `TranscriptOutlineMetrics` inside the centered
        // column, so the native per-level cell shift is disabled.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .none
        outlineView.usesAutomaticRowHeights = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = false

        // Host scroll view (SPEC §5).
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .never
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
        // Stock clip view; layer-backed `.never` so scroll ticks composite
        // the cached bitmap instead of re-running draw.
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layerContentsRedrawPolicy = .never
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    // MARK: - Presentation

    /// One-shot blocking load of `sessionId`'s history, then anchor to the
    /// tail. Tool groups start collapsed (the outline's default) so only
    /// top-level user / markdown nodes show initially (SPEC §4).
    func present(sessionId: String) {
        store.load(sessionId: sessionId)
        outlineView.reloadData()
        scrollToTail()
    }

    /// Scroll so the last row's bottom sits at the visible content edge.
    func scrollToTail() {
        // First layout pass with the dataSource bound tiles the outline at
        // the settled width, so `numberOfRows` / `rect(ofRow:)` are real.
        outlineView.layoutSubtreeIfNeeded()
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return }
        outlineView.scrollRowToVisible(rowCount - 1)
    }

    // MARK: - Row geometry

    /// The row width every horizontal metric derives from. Before the
    /// first real layout pass the outline can still be zero-sized; fall
    /// back to the max column width so early queries stay sane.
    private var rowWidth: CGFloat {
        let width = outlineView.bounds.width
        return width > 1 ? width : BlockStyle.maxLayoutWidth
    }

    private func level(of item: TranscriptNodeItem) -> Int {
        max(0, outlineView.level(forItem: item))
    }

    /// The typeset width for a node — `heightOfRowByItem` and `viewFor`
    /// share this so a row is typeset at exactly one width.
    private func layoutWidth(for item: TranscriptNodeItem) -> CGFloat {
        TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: rowWidth, level: level(of: item),
            hasChevronSlot: item.isHeader)
    }
}

// MARK: - NSOutlineViewDataSource

extension TranscriptViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        store.numberOfChildren(of: item as? TranscriptNodeItem)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        store.child(index, of: item as? TranscriptNodeItem)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TranscriptNodeItem)?.isExpandable ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension TranscriptViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? TranscriptNodeItem else { return nil }
        let cell =
            outlineView.makeView(
                withIdentifier: OutlineBlockCellView.reuseIdentifier, owner: self)
            as? OutlineBlockCellView
            ?? {
                let created = OutlineBlockCellView(frame: .zero)
                created.identifier = OutlineBlockCellView.reuseIdentifier
                return created
            }()
        let nodeLevel = level(of: node)
        cell.level = nodeLevel
        cell.hasChevronSlot = node.isHeader
        cell.layoutWidth = layoutWidth(for: node)
        cell.padTop = store.verticalPadding(for: node, level: nodeLevel).top
        cell.layout = store.rowLayout(for: node, width: cell.layoutWidth)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TranscriptNodeItem else { return 1 }
        return store.height(
            for: node, width: layoutWidth(for: node), level: level(of: node))
    }
}
