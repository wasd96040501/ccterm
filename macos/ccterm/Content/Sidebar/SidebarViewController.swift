import AppKit
import Combine

/// The main window's sidebar: the session library as an Xcode-style source
/// list — projects, their sessions, and under each session its subagents and
/// workflow runs, every row an icon and a title. Opening a row that has a
/// transcript is reported to the delegate; groups only expand.
///
/// A click or Return opens; a double click on a group toggles it.
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

    /// The concrete store rather than a protocol: it has one implementation,
    /// and `LibraryStore(directory:)` over a fixture directory is the test seam.
    init(library: LibraryStore) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var outlineView: SidebarOutlineView = {
        let outline = SidebarOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .sidebarColumn)
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
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
        outlineView.action = #selector(open(_:))
        outlineView.doubleAction = #selector(toggle(_:))
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

    /// The clicked row, or — from the keyboard, or a test sending the action
    /// — the selected one.
    private var actedItem: Item? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? Item
    }

    @objc private func open(_ sender: Any?) {
        guard let item = actedItem, item.node.transcriptURL != nil else { return }
        delegate?.sidebarViewController(self, didOpen: item.node)
    }

    @objc private func toggle(_ sender: Any?) {
        guard let item = actedItem, !item.children.isEmpty else { return }
        if outlineView.isItemExpanded(item) {
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
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: .sidebarCell, owner: nil) as? SidebarCellView
            ?? SidebarCellView()
        cell.configure(with: item.node)
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

/// Return opens the selected row, as a click does.
@MainActor
private final class SidebarOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let action {
            sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// An icon and a title, the source list's standard row.
@MainActor
private final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .sidebarCell
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for subview in [icon, label] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Rewrites every field: cells are reused.
    func configure(with node: LibraryNode) {
        icon.image = NSImage(systemSymbolName: node.kind.symbolName, accessibilityDescription: nil)
        label.stringValue = node.title
        toolTip = node.kind == .project ? node.id : node.title
    }
}

extension LibraryNode.Kind {
    fileprivate var symbolName: String {
        switch self {
        case .project: "folder"
        case .session: "bubble.left.and.bubble.right"
        case .subagents: "person.2"
        case .workflow: "flowchart"
        case .agent: "person.crop.circle"
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let sidebarColumn = NSUserInterfaceItemIdentifier("sidebar.column")
    fileprivate static let sidebarCell = NSUserInterfaceItemIdentifier("sidebar.cell")
}
