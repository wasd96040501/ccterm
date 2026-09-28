import AppKit

/// One editor: a row of tabs over the content of the selected one.
///
/// **The tabs are an `NSTabViewController`'s**, in `.unspecified` style — AppKit's
/// own container for "one of these view controllers at a time", with the tab UI
/// left to the caller. So a tab is an `NSTabViewItem` carrying its view
/// controller, label and image; the view controller is a child, with the
/// lifecycle that comes with it; and a view controller's view is **not loaded
/// until its tab is first selected**, and is out of the window whenever another
/// tab is. Ten tabs cost one on-screen editor, which is the whole of this type's
/// performance story.
///
/// What is added is the order a pinned tab keeps: the first
/// `numberOfPinnedTabs` items are the pinned ones, always. Pinning a tab moves it
/// to the end of that run; unpinning moves it to the start of the rest. A count
/// rather than a flag per tab because the invariant *is* the order — a set of
/// pinned tabs could disagree with it, and a count cannot.
///
/// Everything that crosses editors — moving a tab to the other one, which editor
/// is active, closing an editor that ran out of tabs — is the enclosing
/// `EditorAreaViewController`'s, reached as `parent`.
@MainActor
public final class EditorGroupViewController: NSViewController {

    private let tabs = NSTabViewController()
    lazy var tabBar = EditorTabBar()

    public private(set) var numberOfPinnedTabs = 0

    private var itemObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    /// Where the content starts: under the tab bar, or at the top when there is
    /// no bar to be under. One of the two is active at a time.
    private lazy var contentBelowTabBar = tabs.view.topAnchor.constraint(equalTo: separator.bottomAnchor)
    private lazy var contentAtTop = tabs.view.topAnchor.constraint(equalTo: view.topAnchor)

    private lazy var separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        return box
    }()

    private lazy var emptyLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "No Editor", bundle: .module))
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        label.textColor = .tertiaryLabelColor
        return label
    }()

    /// Where a tab dragged over the content would go, drawn over it.
    private lazy var dropHighlight: NSView = {
        let view = DropHighlightView()
        view.wantsLayer = true
        view.isHidden = true
        return view
    }()

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    var area: EditorAreaViewController? { parent as? EditorAreaViewController }

    // MARK: - View

    public override func loadView() {
        let view = EditorGroupView()
        view.group = self
        self.view = view
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tabs.tabStyle = .unspecified
        // Xcode switches tabs instantly; the default crossfades.
        tabs.transitionOptions = []
        addChild(tabs)
        tabBar.delegate = self
        configureHierarchy()
        configureConstraints()
        reloadTabBar()
    }

    private func configureHierarchy() {
        for subview in [tabBar, separator, tabs.view, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Framed, not constrained: it covers whichever part of the content a
        // drop would take, and is placed only while a drag is over it.
        view.addSubview(dropHighlight)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            tabs.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabs.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Tabs

    public var tabViewItems: [NSTabViewItem] { tabs.tabViewItems }

    /// The selected tab's index, or `-1` when there are none — `NSTabViewController`'s
    /// own convention, which this passes straight through.
    public var selectedTabViewItemIndex: Int {
        get { tabs.selectedTabViewItemIndex }
        set {
            guard newValue != tabs.selectedTabViewItemIndex, tabViewItems.indices.contains(newValue)
            else { return }
            tabs.selectedTabViewItemIndex = newValue
            tabsDidChange()
        }
    }

    public var selectedViewController: NSViewController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex)
            ? tabViewItems[selectedTabViewItemIndex].viewController : nil
    }

    /// Adds a tab after the others and selects it.
    public func addTabViewItem(_ item: NSTabViewItem) {
        insertTabViewItem(item, at: tabViewItems.count)
    }

    /// Inserts a tab and selects it. An index inside the pinned tabs is moved to
    /// just after them: a new tab is never pinned.
    public func insertTabViewItem(_ item: NSTabViewItem, at index: Int) {
        attach(item, pinned: false, at: index)
        tabsDidChange()
    }

    /// Closes a tab, telling the area's delegate first. The tab after it is
    /// selected, or the one before when it was the last.
    public func removeTabViewItem(_ item: NSTabViewItem) {
        guard let index = tabViewItems.firstIndex(of: item) else { return }
        if let area, let viewController = item.viewController {
            area.delegate?.editorArea(area, willClose: viewController)
        }
        detach(at: index)
        tabsDidChange()
    }

    /// The tab something was only looked at in — Xcode's temporary tab, its
    /// title in italics. Setting another closes this one and puts the new one
    /// in its place, selected; setting `nil` keeps this one as an ordinary
    /// tab, as double-clicking it does.
    public var previewTabViewItem: NSTabViewItem? {
        get { preview }
        set {
            guard newValue !== preview else { return }
            if let newValue, !tabViewItems.contains(newValue) {
                if let preview, let index = tabViewItems.firstIndex(of: preview) {
                    removeTabViewItem(preview)
                    insertTabViewItem(newValue, at: index)
                } else {
                    addTabViewItem(newValue)
                }
            }
            preview = newValue
        }
    }

    private weak var preview: NSTabViewItem?

    public func isTabPinned(at index: Int) -> Bool { index < numberOfPinnedTabs }

    /// Pins or unpins a tab, moving it to the boundary between the two runs.
    public func setTabPinned(_ pinned: Bool, at index: Int) {
        guard tabViewItems.indices.contains(index), isTabPinned(at: index) != pinned else { return }
        let selected = selectedViewController
        let item = detach(at: index).item
        attach(item, pinned: pinned, at: numberOfPinnedTabs)
        select(selected)
        tabsDidChange()
    }

    // MARK: - Moving between positions and editors

    /// Takes a tab out without closing it — the half of a move that leaves.
    @discardableResult
    func detach(at index: Int) -> (item: NSTabViewItem, pinned: Bool) {
        let item = tabViewItems[index]
        let pinned = isTabPinned(at: index)
        let wasSelected = index == selectedTabViewItemIndex
        itemObservations[ObjectIdentifier(item)] = nil
        tabs.removeTabViewItem(item)
        if pinned { numberOfPinnedTabs -= 1 }
        if wasSelected, !tabViewItems.isEmpty {
            tabs.selectedTabViewItemIndex = min(index, tabViewItems.count - 1)
        }
        return (item, pinned)
    }

    /// Puts a tab in and selects it, clamped into its own run: a pinned tab
    /// among the pinned, any other after them. Answers where it went.
    @discardableResult
    func attach(_ item: NSTabViewItem, pinned: Bool, at index: Int) -> Int {
        let range = pinned ? 0...numberOfPinnedTabs : numberOfPinnedTabs...tabViewItems.count
        let index = min(max(index, range.lowerBound), range.upperBound)
        tabs.insertTabViewItem(item, at: index)
        if pinned { numberOfPinnedTabs += 1 }
        tabs.selectedTabViewItemIndex = index
        // The bar shows an item's label, image and tooltip, so a change to any of
        // them has to reach it — without this, setting a label after adding the
        // tab would be a property that silently does nothing.
        itemObservations[ObjectIdentifier(item)] = [
            item.observe(\.label) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reloadTabBar() }
            },
            item.observe(\.image) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reloadTabBar() }
            },
            item.observe(\.toolTip) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reloadTabBar() }
            },
        ]
        return index
    }

    /// Moves a tab within this editor, keeping it in its own run and keeping it
    /// selected. Answers where it landed.
    func moveTab(at index: Int, to destination: Int) -> Int {
        let (item, pinned) = detach(at: index)
        let landed = attach(item, pinned: pinned, at: destination)
        tabsDidChange()
        return landed
    }

    private func select(_ viewController: NSViewController?) {
        guard let index = tabViewItems.firstIndex(where: { $0.viewController === viewController })
        else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// Every change to the tabs ends here: the bar redrawn from them, and the
    /// area told, since the active editor or the number of editors may have moved
    /// with it.
    func tabsDidChange() {
        reloadTabBar()
        area?.groupDidChangeTabs(self)
    }

    /// Shows the tabs, and the bar only where there is a choice to make or an
    /// editor to tell apart: more than one tab, or another editor beside this one.
    func reloadTabBar() {
        guard isViewLoaded else { return }
        tabBar.configure(
            items: tabViewItems.enumerated().map { index, item in
                EditorTabBar.Item(
                    id: ObjectIdentifier(item), title: item.label, image: item.image,
                    toolTip: item.toolTip, isPinned: isTabPinned(at: index))
            },
            selectedIndex: tabViewItems.isEmpty ? nil : selectedTabViewItemIndex)
        let showsTabBar = tabViewItems.count > 1 || (area?.groups.count ?? 1) > 1
        tabBar.isHidden = !showsTabBar
        separator.isHidden = !showsTabBar
        let (on, off) = showsTabBar ? (contentBelowTabBar, contentAtTop) : (contentAtTop, contentBelowTabBar)
        off.isActive = false
        on.isActive = true
        emptyLabel.isHidden = !tabViewItems.isEmpty
    }

    // MARK: - The tab menu

    func menu(forTabAt index: Int) -> NSMenu {
        let menu = NSMenu()
        let pinned = isTabPinned(at: index)
        menu.addItem(
            item(
                pinned
                    ? String(localized: "Unpin Tab", bundle: .module)
                    : String(localized: "Pin Tab", bundle: .module),
                index, #selector(togglePinnedFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Close Tab", bundle: .module), index, #selector(closeFromMenu(_:))))
        let others = item(
            String(localized: "Close Other Tabs", bundle: .module), index,
            #selector(closeOthersFromMenu(_:)))
        others.isEnabled = tabViewItems.indices.contains { $0 != index && !isTabPinned(at: $0) }
        menu.addItem(others)
        if let area, let title = area.moveMenuTitle(forTabIn: self) {
            menu.addItem(.separator())
            let move = item(title, index, #selector(moveToOtherEditorFromMenu(_:)))
            move.isEnabled = area.canMoveTab(outOf: self)
            menu.addItem(move)
        }
        menu.autoenablesItems = false
        return menu
    }

    private func item(_ title: String, _ index: Int, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // The item, not the index: the menu is open while nothing stops a
        // streamed tab from moving others, and an item is still the same tab.
        item.representedObject = tabViewItems[index]
        return item
    }

    private func index(of sender: NSMenuItem) -> Int? {
        (sender.representedObject as? NSTabViewItem).flatMap { tabViewItems.firstIndex(of: $0) }
    }

    @objc private func togglePinnedFromMenu(_ sender: NSMenuItem) {
        guard let index = index(of: sender) else { return }
        setTabPinned(!isTabPinned(at: index), at: index)
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem else { return }
        removeTabViewItem(item)
    }

    /// Pinned tabs stay: keeping a tab through exactly this is what pinning it is for.
    @objc private func closeOthersFromMenu(_ sender: NSMenuItem) {
        guard let kept = sender.representedObject as? NSTabViewItem else { return }
        for (index, item) in tabViewItems.enumerated().reversed()
        where item !== kept && !isTabPinned(at: index) {
            removeTabViewItem(item)
        }
    }

    @objc private func moveToOtherEditorFromMenu(_ sender: NSMenuItem) {
        guard let index = index(of: sender) else { return }
        area?.moveTabToOtherGroup(at: index, of: self)
    }

    // MARK: - Dropping a tab on the content

    /// Where a tab dragged from `source` would go if dropped at `point` over the
    /// content, and the part of the content that says so.
    func contentDrop(
        from source: EditorTabBar, at point: NSPoint
    ) -> (rect: NSRect, perform: () -> Void)? {
        guard let area, let sourceGroup = source.delegate as? EditorGroupViewController,
            let dragged = source.draggedIndex
        else { return nil }
        let content = tabs.view.frame
        if sourceGroup === self {
            // Onto its own editor: the trailing half opens a new one on the right.
            guard point.x >= content.midX, area.canMoveTab(outOf: self),
                area.groups.count < EditorAreaViewController.maximumNumberOfGroups
            else { return nil }
            let half = NSRect(
                x: content.midX, y: content.minY, width: content.width / 2, height: content.height)
            return (half, { area.moveTabToOtherGroup(at: dragged, of: sourceGroup) })
        }
        return (
            content,
            {
                area.moveTab(
                    at: dragged, of: sourceGroup, to: self, at: self.tabViewItems.count)
            }
        )
    }

    func showDropHighlight(_ rect: NSRect?) {
        dropHighlight.isHidden = rect == nil
        guard let rect else { return }
        dropHighlight.frame = rect.insetBy(dx: 4, dy: 4)
    }
}

extension EditorGroupViewController: EditorTabBarDelegate {

    func tabBar(_ tabBar: EditorTabBar, didSelectTabAt index: Int) {
        area?.activate(self)
        selectedTabViewItemIndex = index
    }

    func tabBar(_ tabBar: EditorTabBar, didCloseTabAt index: Int) {
        guard tabViewItems.indices.contains(index) else { return }
        removeTabViewItem(tabViewItems[index])
    }

    func tabBar(_ tabBar: EditorTabBar, menuForTabAt index: Int) -> NSMenu? {
        menu(forTabAt: index)
    }

    /// The tab's content as it is on screen, which only the selected tab's is —
    /// and a tab being dragged was selected by the press that picked it up.
    func tabBar(_ tabBar: EditorTabBar, draggingImageForTabAt index: Int) -> NSImage? {
        guard tabViewItems.indices.contains(index), let viewController = tabViewItems[index].viewController,
            viewController.isViewLoaded, viewController.view.window != nil
        else { return nil }
        let view = viewController.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func tabBar(
        _ tabBar: EditorTabBar, moveTabAt index: Int, of source: EditorTabBar, to destination: Int
    ) -> Int? {
        guard let sourceGroup = source.delegate as? EditorGroupViewController else { return nil }
        if sourceGroup === self { return moveTab(at: index, to: destination) }
        return area?.moveTab(at: index, of: sourceGroup, to: self, at: destination)
    }
}

/// The group's root view: where a tab dropped on the content, rather than on a
/// bar, is received.
///
/// A view rather than the controller because dragging destinations are views.
/// It knows nothing about tabs; the group says what a drop means.
@MainActor
private final class EditorGroupView: NSView {

    weak var group: EditorGroupViewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.editorTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    private func drop(for sender: NSDraggingInfo) -> (rect: NSRect, perform: () -> Void)? {
        guard let source = sender.draggingSource as? EditorTabBar else { return nil }
        return group?.contentDrop(from: source, at: convert(sender.draggingLocation, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = drop(for: sender)
        group?.showDropHighlight(drop?.rect)
        return drop == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        group?.showDropHighlight(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        group?.showDropHighlight(nil)
        guard let drop = drop(for: sender) else { return false }
        drop.perform()
        return true
    }
}

/// A tinted, outlined rectangle over the content: where a dropped tab would go.
/// Never hit by the mouse.
@MainActor
private final class DropHighlightView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
    }
}
