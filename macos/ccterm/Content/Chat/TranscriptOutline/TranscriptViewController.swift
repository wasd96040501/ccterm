import AppKit

/// The outline transcript's view controller: builds the
/// `NSScrollView` (host) + `TranscriptClipView` + stock `NSOutlineView`
/// tree, binds itself as the outline's dataSource / delegate, and drives
/// data from the injected `TranscriptStore`. A thin coordinator — all
/// state (tree + layout cache) lives in the store; this VC only maps
/// outline callbacks onto store queries and mounts cells (SPEC §6.2).
///
/// The `NSOutlineView` is used stock (no subclass): the disclosure
/// triangle and per-level indent are native. Horizontal centering is the
/// `TranscriptClipView`'s job, so the outline is a fixed-width [460, 780]
/// document (SPEC §5).
@MainActor
final class TranscriptViewController: NSViewController {
    private let store: TranscriptStore

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    init(store: TranscriptStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View tree

    override func loadView() {
        let host = NSView()

        // Stock outline — fixed-width document, native triangle + indent.
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
        outlineView.translatesAutoresizingMaskIntoConstraints = false

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
        // Assign the centering clip BEFORE the insets, per SPEC §5.
        scrollView.contentView = TranscriptClipView()
        scrollView.contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)

        let clip = scrollView.contentView
        let widthMatch = outlineView.widthAnchor.constraint(equalTo: clip.widthAnchor)
        widthMatch.priority = .defaultLow

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            outlineView.widthAnchor.constraint(
                lessThanOrEqualToConstant: BlockStyle.maxLayoutWidth),
            outlineView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: BlockStyle.minLayoutWidth),
            widthMatch,
            outlineView.topAnchor.constraint(equalTo: clip.topAnchor),
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

    // MARK: - Width

    /// The content width a node's cell will have — the outline's width
    /// minus the native indent (per-level offset + disclosure column).
    /// `heightOfRowByItem` and `viewFor` share this so a row is typeset at
    /// exactly one width.
    private func contentWidth(for item: TranscriptNodeItem) -> CGFloat {
        let outlineW = outlineView.bounds.width
        let base = outlineW > 1 ? outlineW : BlockStyle.maxLayoutWidth
        let level = max(0, outlineView.level(forItem: item))
        let indent = CGFloat(level + 1) * outlineView.indentationPerLevel
        return max(1, base - indent)
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
        let width = contentWidth(for: node)
        cell.layout = store.rowLayout(for: node, width: width)
        cell.padTop = store.verticalPadding(for: node).top
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TranscriptNodeItem else { return 1 }
        return store.height(for: node, width: contentWidth(for: node))
    }
}
