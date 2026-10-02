import AppKit
import Combine
import UniformTypeIdentifiers

/// The main window's sidebar: the session library as an Xcode-style source
/// list — projects, their sessions, and under each session its subagents and
/// workflow runs, every row an icon and a title.
///
/// Until the library's first read it shows that it is loading, as System
/// Settings does: a small spinner beside a line of secondary text.
///
/// Selecting a row with a transcript reports `didSelect`, double-clicking it
/// `didOpen`; a double click on a group toggles it. A row with a transcript
/// drags as its file.
@MainActor
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let nodes: AnyPublisher<[LibraryNode]?, Never>
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

    private let activities: AnyPublisher<[URL: SessionState.Activity], Never>
    /// Each live session's activity, by transcript URL, as last published.
    private var shownActivities: [URL: SessionState.Activity] = [:]

    /// `nodes`: the library's tree, current value first, then each change;
    /// `nil` until the library is first read. `activities`: each live
    /// session's, by transcript URL. Both deliver on the main actor.
    init(
        nodes: AnyPublisher<[LibraryNode]?, Never>,
        activities: AnyPublisher<[URL: SessionState.Activity], Never>
    ) {
        self.nodes = nodes
        self.activities = activities
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var outlineView: NSOutlineView = {
        let outline = NSOutlineView()
        outline.style = .sourceList
        // Xcode's navigator geometry, which keeps its own size rather than
        // the system sidebar's.
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
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

    /// Rebuilt for the clicked row each time it opens (`menuNeedsUpdate`): End
    /// Session on a live session, nothing — so no menu — elsewhere.
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }()

    private lazy var spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        return spinner
    }()

    private lazy var loadingLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "Loading…"))
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var loadingView: NSStackView = {
        let stack = NSStackView(views: [spinner, loadingLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
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
        outlineView.action = #selector(click(_:))
        outlineView.doubleAction = #selector(doubleClick(_:))
        outlineView.menu = contextMenu
        // Sunk directly: the current value lands now, so a window shown on the
        // library's first read shows its tree, not the spinner.
        nodes
            .sink { [weak self] nodes in MainActor.assumeIsolated { self?.show(nodes) } }
            .store(in: &cancellables)
        activities
            .sink { [weak self] activities in MainActor.assumeIsolated { self?.show(activities) } }
            .store(in: &cancellables)
    }

    /// Redraws the rows whose activity changed — a session's, and the groups
    /// above it, which show their most urgent session's while collapsed —
    /// and only those: activities change far more often than the tree.
    private func show(_ activities: [URL: SessionState.Activity]) {
        let previous = shownActivities
        shownActivities = activities
        let changed = Set(previous.keys).union(activities.keys).filter { previous[$0] != activities[$0] }
        guard !changed.isEmpty else { return }
        var rows = IndexSet()
        /// Whether `item` or anything under it is a changed session; every
        /// such item is redrawn, which is the changed rows and their ancestors.
        @discardableResult
        func collect(_ item: Item) -> Bool {
            var affected = item.node.transcriptURL.map(changed.contains) ?? false
            for child in item.children where collect(child) { affected = true }
            if affected {
                let row = outlineView.row(forItem: item)
                if row >= 0 { rows.insert(row) }
            }
            return affected
        }
        for root in roots { collect(root) }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    /// The mark a row draws: a session's own activity, and for a group,
    /// while it is collapsed, its most urgent session's — an expanded group
    /// leaves each session to show its own.
    private func activity(of item: Item) -> SessionState.Activity? {
        if outlineView.isItemExpanded(item) { return item.node.transcriptURL.flatMap { shownActivities[$0] } }
        return item.node.mostUrgentActivity(in: shownActivities)
    }

    private func configureHierarchy() {
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Data

    private func show(_ nodes: [LibraryNode]?) {
        showLoading(nodes == nil)
        guard let nodes else { return }
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

    private func showLoading(_ loading: Bool) {
        loadingView.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: - Actions

    /// A click reports its row even when the row was already selected: its tab
    /// may have closed since.
    @objc private func click(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? Item, item.node.transcriptURL != nil
        else { return }
        delegate?.sidebarViewController(self, didSelect: item.node)
    }

    @objc private func endSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? LibraryNode else { return }
        delegate?.sidebarViewController(self, didRequestEndOf: node)
    }

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
        let cell = outlineView.makeView(withIdentifier: .sidebarCell, owner: nil) as? Cell ?? Cell()
        cell.imageView?.image = item.node.kind.image
        cell.iconTint = item.node.kind.tintColor
        cell.objectValue = item.node.title
        cell.toolTip = item.node.kind == .project ? item.node.id : item.node.title
        cell.activity = activity(of: item)
        return cell
    }

    /// A group's mark depends on whether it is open.
    func outlineViewItemDidExpand(_ notification: Notification) { reloadRow(of: notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { reloadRow(of: notification) }

    private func reloadRow(of notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Item else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    /// Type-to-select, which AppKit would otherwise read from the cell's
    /// `textField` — a `Cell` has none.
    func outlineView(
        _ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any
    )
        -> String?
    {
        (item as? Item)?.node.title
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

}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? Item,
            let url = item.node.transcriptURL, shownActivities[url] != nil
        else { return }
        let end = NSMenuItem(
            title: String(localized: "End Session"), action: #selector(endSession(_:)), keyEquivalent: "")
        end.target = self
        end.representedObject = item.node
        menu.addItem(end)
    }
}

// MARK: - Activity

extension SessionState.Activity {
    /// How urgently the reader's eye is wanted: a request to answer first,
    /// then a failure, then work in flight, then a session merely open.
    fileprivate var urgency: Int {
        switch self {
        case .needsInput: 3
        case .failed: 2
        case .responding: 1
        case .idle: 0
        }
    }

    /// The most urgent of `activities`, `nil` when there are none.
    static func mostUrgent(of activities: some Sequence<SessionState.Activity>) -> SessionState.Activity? {
        activities.max { $0.urgency < $1.urgency }
    }

    fileprivate var accessibilityLabel: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .responding: String(localized: "Responding")
        case .needsInput: String(localized: "Needs Your Input")
        case .failed: String(localized: "Failed")
        }
    }
}

extension LibraryNode {
    /// The most urgent activity of this node's own session and of every
    /// session under it, `nil` when none is live.
    func mostUrgentActivity(in activities: [URL: SessionState.Activity]) -> SessionState.Activity? {
        var found: [SessionState.Activity] = []
        func visit(_ node: LibraryNode) {
            if let url = node.transcriptURL, let activity = activities[url] { found.append(activity) }
            node.children.forEach(visit)
        }
        visit(self)
        return .mostUrgent(of: found)
    }
}

// MARK: - Cell

extension SidebarViewController {
    /// The source list's row: an icon and its title, which is the cell's
    /// `objectValue`.
    ///
    /// The title is deliberately not the cell's `textField`: a source list
    /// rewrites its `textField` semibold while the row is selected, and Xcode's
    /// navigator keeps a selected title's weight. As a plain subview it still
    /// turns white on an emphasized row — the cell forwards `backgroundStyle` to
    /// every control in it — and the drag image adds it back, since AppKit
    /// builds one only from `imageView` and `textField`.
    private final class Cell: NSTableCellView {
        private let title = NSTextField(labelWithString: "")
        private let mark = ActivityMarkView()
        /// The mark's slot: its width while one shows, none otherwise, so a
        /// row at rest gives its title the whole line.
        private lazy var markWidth = mark.widthAnchor.constraint(equalToConstant: 0)

        /// The session's state, drawn as a small trailing mark; `nil` draws none.
        var activity: SessionState.Activity? {
            didSet {
                mark.activity = activity
                markWidth.constant = activity == nil ? 0 : ActivityMarkView.slot
            }
        }

        override var objectValue: Any? {
            didSet { title.stringValue = objectValue as? String ?? "" }
        }

        /// The icon's own colour. On a selected, focused row it gives way to
        /// the row's white, as the title does.
        var iconTint: NSColor? {
            didSet { showIconTint() }
        }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet {
                showIconTint()
                mark.isEmphasized = backgroundStyle == .emphasized
            }
        }

        private func showIconTint() {
            imageView?.contentTintColor = backgroundStyle == .emphasized ? nil : iconTint
        }

        init() {
            super.init(frame: .zero)
            identifier = .sidebarCell
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            imageView = image
            title.font = .systemFont(ofSize: NSFont.systemFontSize)
            title.lineBreakMode = .byTruncatingTail
            for subview in [image, title, mark] as [NSView] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                addSubview(subview)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                title.trailingAnchor.constraint(lessThanOrEqualTo: mark.leadingAnchor),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                mark.centerYAnchor.constraint(equalTo: centerYAnchor),
                markWidth,
                mark.heightAnchor.constraint(equalToConstant: ActivityMarkView.slot),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var draggingImageComponents: [NSDraggingImageComponent] {
            guard let rep = title.bitmapImageRepForCachingDisplay(in: title.bounds) else {
                return super.draggingImageComponents
            }
            title.cacheDisplay(in: title.bounds, to: rep)
            let image = NSImage(size: title.bounds.size)
            image.addRepresentation(rep)
            let component = NSDraggingImageComponent(key: .label)
            component.contents = image
            component.frame = convert(title.bounds, from: title)
            return super.draggingImageComponents + [component]
        }
    }
}

// MARK: - Activity mark

extension SidebarViewController {
    /// A live session's state, one small mark at the row's trailing edge
    /// (design/sidebar-icons): idle a quiet dot, needs-input a coral dot, failed
    /// a red one, and responding a ring with an arc travelling it — the
    /// tile's motion, since a running thing moves and isn't coloured. On a
    /// selected, focused row every mark is white, as the icon is. Reduce Motion
    /// stills the arc.
    private final class ActivityMarkView: NSView {
        /// The width and height of the mark's slot.
        static let slot: CGFloat = 14

        private let shape = CAShapeLayer()

        var activity: SessionState.Activity? {
            didSet {
                guard activity != oldValue else { return }
                setAccessibilityLabel(activity?.accessibilityLabel)
                update()
            }
        }

        var isEmphasized = false {
            didSet {
                guard isEmphasized != oldValue else { return }
                needsDisplay = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(shape)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            update()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
        }

        override func layout() {
            super.layout()
            // The shape is its own centred square, so the arc turns about its middle.
            let side = Self.slot
            shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }

        private func update() {
            isHidden = activity == nil
            let side = Self.slot
            let path = CGMutablePath()
            if case .responding = activity {
                path.addEllipse(in: CGRect(x: 2, y: 2, width: side - 4, height: side - 4))
            } else {
                path.addEllipse(in: CGRect(x: (side - 6) / 2, y: (side - 6) / 2, width: 6, height: 6))
            }
            shape.path = path
            needsDisplay = true
            animate()
        }

        /// Colours are resolved here, in the view's appearance, so they follow
        /// light and dark.
        private func paint() {
            let colour: NSColor? =
                switch activity {
                case .idle: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
                case .responding: .secondaryLabelColor
                case .needsInput: NSColor(resource: .sidebarCoral)
                case .failed: .systemRed
                case nil: nil
                }
            // The white of a selected row, quieter for the quiet dot.
            let ink = isEmphasized ? NSColor.white.withAlphaComponent(activity == .idle ? 0.55 : 1) : colour
            if case .responding = activity {
                shape.fillColor = nil
                shape.strokeColor = ink?.cgColor
                shape.lineWidth = 1.5
                shape.lineCap = .round
                shape.strokeStart = 0
                shape.strokeEnd = 1.0 / 3
            } else {
                shape.fillColor = ink?.cgColor
                shape.strokeColor = nil
                shape.strokeEnd = 1
            }
        }

        private func animate() {
            shape.removeAllAnimations()
            guard case .responding = activity, window != nil,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 1
            turn.repeatCount = .infinity
            shape.add(turn, forKey: "turn")
        }
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
    /// A group is a folder, drawn with the system's folder icon as Finder and
    /// Xcode draw one — except a workflow run, which has its own glyph, as a
    /// conversation and a subagent do (`design/sidebar-icons`).
    fileprivate var image: NSImage? {
        switch self {
        case .project, .subagents: NSWorkspace.shared.icon(for: .folder)
        case .session: NSImage(resource: .sidebarSession)
        case .agent: NSImage(resource: .sidebarAgent)
        case .workflow: NSImage(resource: .sidebarWorkflow)
        }
    }

    /// A glyph's colour, as Xcode's navigator gives each file type one
    /// (`design/sidebar-icons`). The folder icon has its own colours and
    /// takes none.
    fileprivate var tintColor: NSColor? {
        switch self {
        case .project, .subagents: nil
        case .session: NSColor(resource: .sidebarCoral)
        case .agent: .systemGray
        case .workflow: .systemIndigo
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let sidebarColumn = NSUserInterfaceItemIdentifier("sidebar.column")
    fileprivate static let sidebarCell = NSUserInterfaceItemIdentifier("sidebar.cell")
}
