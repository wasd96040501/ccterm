import AppKit
import Combine

/// The main window's sidebar: the session library as an Xcode-style source
/// list — projects, their sessions, and under each session its subagents and
/// workflow runs, every row an icon and a title.
///
/// Selecting a row with a transcript reports `didSelect`, double-clicking it
/// `didOpen`; a double click on a group toggles it. A row with a transcript
/// drags as its file.
@MainActor
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let library: LibraryStore
    private var cancellables = Set<AnyCancellable>()

    /// The outline's items. `NSOutlineView` tells items apart by identity and
    /// every publish is a new tree, so each node id keeps one `Item` for as
    /// long as it is in the library — which is what keeps expansion and
    /// selection across a republish.
    private var roots: [Item] = []
    private var items: [String: Item] = [:]
    /// The node last reported selected, so restoring the selection after a
    /// republish isn't reported again.
    private var reportedSelection: String?

    /// The concrete store rather than a protocol: it has one implementation,
    /// and `LibraryStore(directory:)` over a fixture directory is the test seam.
    init(library: LibraryStore) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var outlineView: NSOutlineView = {
        let outline = NSOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .sidebarColumn)
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        return outline
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureConstraints()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClick(_:))
        library.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nodes in self?.show(nodes) }
            .store(in: &cancellables)
    }

    private func configureHierarchy() {
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Data

    private func show(_ nodes: [LibraryNode]) {
        let selected = outlineView.item(atRow: outlineView.selectedRow) as? Item
        var kept: [String: Item] = [:]
        func item(for node: LibraryNode) -> Item {
            let item = items[node.id] ?? Item(node)
            item.node = node
            item.children = node.children.map(item(for:))
            kept[node.id] = item
            return item
        }
        roots = nodes.map(item(for:))
        items = kept
        outlineView.reloadData()
        if let selected, kept[selected.node.id] === selected {
            let row = outlineView.row(forItem: selected)
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    // MARK: - Actions

    @objc private func doubleClick(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? Item else { return }
        if item.node.transcriptURL != nil {
            delegate?.sidebarViewController(self, didOpen: item.node)
        } else if outlineView.isItemExpanded(item) {
            outlineView.animator().collapseItem(item)
        } else {
            outlineView.animator().expandItem(item)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? Item)?.node.transcriptURL as NSURL?
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let cell = outlineView.makeView(withIdentifier: .sidebarCell, owner: nil) as? NSTableCellView ?? Self.makeCell()
        cell.imageView?.image = NSImage(systemSymbolName: item.node.kind.symbolName, accessibilityDescription: nil)
        cell.textField?.stringValue = item.node.title
        cell.toolTip = item.node.kind == .project ? item.node.id : item.node.title
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else {
            reportedSelection = nil
            return
        }
        guard item.node.id != reportedSelection else { return }
        reportedSelection = item.node.id
        guard item.node.transcriptURL != nil else { return }
        delegate?.sidebarViewController(self, didSelect: item.node)
    }

    /// The source list's standard row: an image and a label.
    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .sidebarCell
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        for subview in [image, label] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Item

extension SidebarViewController {
    /// One outline row: a node, and the items of its children.
    private final class Item {
        var node: LibraryNode
        var children: [Item] = []

        init(_ node: LibraryNode) {
            self.node = node
        }
    }
}

extension LibraryNode.Kind {
    fileprivate var symbolName: String {
        switch self {
        case .project: "folder.fill"
        case .session: "bubble.left.fill"
        case .subagents: "person.2.fill"
        case .workflow: "flowchart.fill"
        case .agent: "person.crop.circle.fill"
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let sidebarColumn = NSUserInterfaceItemIdentifier("sidebar.column")
    fileprivate static let sidebarCell = NSUserInterfaceItemIdentifier("sidebar.cell")
}
