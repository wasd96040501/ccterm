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
/// What is added is Xcode 26's pin and Xcode's history. **A tab is pinned unless
/// it is the temporary tab** (`previewTabViewItem`): pinning is keeping, so there
/// is one state, not a flag beside the temporary tab that could disagree with it.
/// **The history** is what the editor has shown, by `NSTabViewItem.identifier`,
/// which this type compares and never looks inside; going back to something whose
/// tab has closed asks the area's delegate for a new one.
///
/// Everything that crosses editors — moving a tab to the other one, which editor
/// is active, closing an editor that ran out of tabs — and everything that
/// reaches the host is its `delegate`'s: the area it is in, which this type
/// never names.
@MainActor
public final class EditorGroupViewController: NSViewController {

    /// Where an editor is among the editors — which decides where a tab can move
    /// out of it to, and what that is called. Two editors at most, so an editor
    /// that is the only one is one beside which another can open.
    enum Position {
        case only, left, right
    }

    weak var delegate: EditorGroupViewControllerDelegate?

    private let tabs = NSTabViewController()
    lazy var tabBar = EditorTabBar()

    private var itemObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    private var history = History()

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

    /// Made by the area only.
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

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

    /// The bar hangs from the safe area: under a window's toolbar when the editor
    /// reaches under it (a full-size content view), which is the titlebar's to
    /// take clicks in — for moving and zooming the window, not for dragging tabs.
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            tabs.view.topAnchor.constraint(equalTo: separator.bottomAnchor),
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

    var selectedViewController: NSViewController? { selectedTabViewItem?.viewController }

    var selectedTabViewItem: NSTabViewItem? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex] : nil
    }

    /// Adds a tab after the others and selects it.
    public func addTabViewItem(_ item: NSTabViewItem) {
        insertTabViewItem(item, at: tabViewItems.count)
    }

    /// Inserts a tab and selects it.
    func insertTabViewItem(_ item: NSTabViewItem, at index: Int) {
        attach(item, at: index)
        tabsDidChange()
    }

    /// Closes a tab, telling the area's delegate first. The tab after it is
    /// selected, or the one before when it was the last.
    public func removeTabViewItem(_ item: NSTabViewItem) {
        guard let index = tabViewItems.firstIndex(of: item) else { return }
        close(at: index)
        tabsDidChange()
    }

    /// The tab something was only looked at in — Xcode's temporary tab, its
    /// title in italics and its pin hollow. Setting a tab not in the editor
    /// closes this one and puts the new one in its place, selected, as one change;
    /// setting one of the editor's tabs makes that the temporary one and pins
    /// this; setting `nil` pins this, as double-clicking it or its pin does. A
    /// temporary tab moved to the other editor is pinned there.
    public var previewTabViewItem: NSTabViewItem? {
        get { preview.flatMap { tabViewItems.contains($0) ? $0 : nil } }
        set {
            let current = previewTabViewItem
            guard newValue !== current else { return }
            preview = newValue
            guard let newValue, !tabViewItems.contains(newValue) else { return tabsDidChange() }
            let index = current.flatMap { tabViewItems.firstIndex(of: $0) }
            if let index { close(at: index) }
            attach(newValue, at: index ?? tabViewItems.count)
            tabsDidChange()
        }
    }

    private weak var preview: NSTabViewItem?

    // MARK: - History

    /// Whether there is something this editor showed before what it shows now.
    var canGoBack: Bool { history.entry(at: -1) != nil }

    /// Whether this editor went back from something it can show again.
    var canGoForward: Bool { history.entry(at: 1) != nil }

    /// Shows what the editor showed before: its tab if it is still open, else a
    /// new temporary tab the area's delegate makes for it
    /// (`editorArea(_:tabViewItemWithIdentifier:)`). What the delegate can't
    /// make is passed over, and forgotten.
    func goBack() {
        navigate(by: -1)
    }

    /// Shows what `goBack()` went back from, as `goBack()` shows.
    func goForward() {
        navigate(by: 1)
    }

    /// Moves `offset` entries along the history to the nearest one that can be
    /// shown, and shows it. The history moves first, so the tab change showing
    /// it is what the history already says, and records nothing.
    private func navigate(by offset: Int) {
        while let identifier = history.entry(at: offset) {
            guard let item = tabViewItem(showing: identifier) else {
                history.remove(at: offset)
                continue
            }
            history.move(by: offset)
            show(item)
            return
        }
    }

    /// The open tab showing `identifier`, or a new one the area's delegate makes.
    private func tabViewItem(showing identifier: AnyHashable) -> NSTabViewItem? {
        if let item = tabViewItems.first(where: { $0.identifier as? AnyHashable == identifier }) { return item }
        return delegate?.editorGroup(self, tabViewItemWithIdentifier: identifier)
    }

    /// Selects `item`, opening it as the temporary tab if it isn't open.
    private func show(_ item: NSTabViewItem) {
        if let index = tabViewItems.firstIndex(of: item) {
            selectedTabViewItemIndex = index
        } else {
            previewTabViewItem = item
        }
    }

    // MARK: - Moving between positions and editors

    /// Closes the tab at `index`: the area's delegate told, then the tab taken out.
    private func close(at index: Int) {
        if let viewController = tabViewItems[index].viewController {
            delegate?.editorGroup(self, willClose: viewController)
        }
        detach(at: index)
    }

    /// Takes a tab out without closing it — the half of a move that leaves.
    @discardableResult
    func detach(at index: Int) -> NSTabViewItem {
        let item = tabViewItems[index]
        let wasSelected = index == selectedTabViewItemIndex
        itemObservations[ObjectIdentifier(item)] = nil
        tabs.removeTabViewItem(item)
        if wasSelected, !tabViewItems.isEmpty {
            tabs.selectedTabViewItemIndex = min(index, tabViewItems.count - 1)
        }
        return item
    }

    /// Puts a tab in at `index`, clamped to the tabs there are, and selects it.
    /// Answers where it went.
    @discardableResult
    func attach(_ item: NSTabViewItem, at index: Int) -> Int {
        let index = min(max(index, 0), tabViewItems.count)
        tabs.insertTabViewItem(item, at: index)
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

    /// Moves a tab within this editor, keeping it selected. Answers where it
    /// landed.
    func moveTab(at index: Int, to destination: Int) -> Int {
        let landed = attach(detach(at: index), at: destination)
        tabsDidChange()
        return landed
    }

    /// Every change to the tabs ends here: the history told what is shown now,
    /// the bar redrawn from the tabs, and the area told, since the active editor
    /// or the number of editors may have moved with it. An empty editor, or a
    /// tab with no identifier, shows nothing the history could return to.
    func tabsDidChange() {
        if let identifier = selectedTabViewItem?.identifier as? AnyHashable { history.visit(identifier) }
        reloadTabBar()
        delegate?.editorGroupDidChangeTabs(self)
    }

    /// Shows the tabs. The bar is there while there are any, one or more: it is
    /// where the tabs are, not a control that appears when there is a choice.
    func reloadTabBar() {
        guard isViewLoaded else { return }
        tabBar.configure(
            items: tabViewItems.map { item in
                EditorTabBar.Item(
                    id: ObjectIdentifier(item), title: item.label, image: item.image,
                    toolTip: item.toolTip, isPreview: item === previewTabViewItem)
            },
            selectedIndex: tabViewItems.isEmpty ? nil : selectedTabViewItemIndex)
        tabBar.isHidden = tabViewItems.isEmpty
        separator.isHidden = tabViewItems.isEmpty
        emptyLabel.isHidden = !tabViewItems.isEmpty
    }

    /// Pins the tab at `index`, or makes it the temporary tab if it is pinned —
    /// what its pin does.
    func togglePinned(at index: Int) {
        guard tabViewItems.indices.contains(index) else { return }
        let item = tabViewItems[index]
        previewTabViewItem = item === previewTabViewItem ? nil : item
    }

    // MARK: - The tab menu

    func menu(forTabAt index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            item(
                tabViewItems[index] === previewTabViewItem
                    ? String(localized: "Pin Tab", bundle: .module)
                    : String(localized: "Unpin Tab", bundle: .module),
                index, #selector(togglePinnedFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Close Tab", bundle: .module), index, #selector(closeFromMenu(_:))))
        let others = item(
            String(localized: "Close Other Tabs", bundle: .module), index,
            #selector(closeOthersFromMenu(_:)))
        others.isEnabled = tabViewItems.count > 1
        menu.addItem(others)
        if let position = delegate?.position(of: self) {
            menu.addItem(.separator())
            let move = item(Self.moveMenuTitle(at: position), index, #selector(moveToOtherEditorFromMenu(_:)))
            move.isEnabled = canMoveTabOut(at: position)
            menu.addItem(move)
        }
        menu.autoenablesItems = false
        return menu
    }

    /// What the tab menu calls moving a tab out of an editor at `position`.
    private static func moveMenuTitle(at position: Position) -> String {
        switch position {
        case .only: String(localized: "Move to New Editor on Right", bundle: .module)
        case .left: String(localized: "Move to Editor on Right", bundle: .module)
        case .right: String(localized: "Move to Editor on Left", bundle: .module)
        }
    }

    /// Whether a tab can leave this editor, at `position`, for the other one.
    /// Moving an editor's only tab into a new editor beside it would leave this
    /// one empty and closing — the same layout, moved over — so that one is
    /// refused.
    private func canMoveTabOut(at position: Position) -> Bool {
        position != .only || tabViewItems.count > 1
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
        togglePinned(at: index)
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem else { return }
        removeTabViewItem(item)
    }

    /// Every other tab, pinned or not: a pin keeps a tab from being replaced,
    /// which is a different thing from being closed on purpose.
    @objc private func closeOthersFromMenu(_ sender: NSMenuItem) {
        guard let kept = sender.representedObject as? NSTabViewItem else { return }
        for item in tabViewItems.reversed() where item !== kept {
            removeTabViewItem(item)
        }
    }

    @objc private func moveToOtherEditorFromMenu(_ sender: NSMenuItem) {
        guard let index = index(of: sender) else { return }
        delegate?.editorGroup(self, moveTabToOtherGroupAt: index)
    }

    // MARK: - Dropping a tab on the content

    /// Where a tab dragged from `source` would go if dropped at `point` over the
    /// content, and the part of the content that says so.
    func contentDrop(
        from source: EditorTabBar, at point: NSPoint
    ) -> (rect: NSRect, perform: () -> Void)? {
        guard let delegate, let sourceGroup = source.delegate as? EditorGroupViewController,
            let dragged = source.draggedIndex
        else { return nil }
        let content = tabs.view.frame
        if sourceGroup === self {
            // Onto its own editor: the trailing half opens a new one on the right.
            guard point.x >= content.midX, delegate.position(of: self) == .only, canMoveTabOut(at: .only)
            else { return nil }
            let half = NSRect(
                x: content.midX, y: content.minY, width: content.width / 2, height: content.height)
            return (half, { delegate.editorGroup(self, moveTabToOtherGroupAt: dragged) })
        }
        return (
            content,
            {
                _ = delegate.editorGroup(
                    self, moveTabAt: dragged, of: sourceGroup, to: self.tabViewItems.count)
            }
        )
    }

    /// Something from outside the editors dropped on the content: on the
    /// trailing half, while a second editor can open, it opens there; anywhere
    /// else it becomes this editor's last tab. `nil` when the drag carries
    /// nothing the area takes. Performing it answers whether it opened.
    func contentDrop(of drop: NSDraggingInfo, at point: NSPoint) -> (rect: NSRect, perform: () -> Bool)? {
        guard let delegate, drop.draggingPasteboard.availableType(from: acceptedTypes) != nil else { return nil }
        let content = tabs.view.frame
        if point.x >= content.midX, !tabViewItems.isEmpty, delegate.position(of: self) == .only {
            let half = NSRect(x: content.midX, y: content.minY, width: content.width / 2, height: content.height)
            return (
                half,
                {
                    guard let item = self.tabViewItem(for: drop) else { return false }
                    delegate.editorGroup(self, openNewGroupWith: item)
                    return true
                }
            )
        }
        return (content, { self.open(drop, at: self.tabViewItems.count) })
    }

    /// Lets the editor take drops of `types` from outside, beside dragged tabs.
    func acceptDrops(of types: [NSPasteboard.PasteboardType]) {
        acceptedTypes = types
        view.registerForDraggedTypes([.editorTab] + types)
        tabBar.registerForDraggedTypes([.editorTab] + types)
    }

    /// What from outside the editors this one takes, beside dragged tabs.
    private var acceptedTypes: [NSPasteboard.PasteboardType] = []

    /// Opens a drop from outside as a tab at `index`, if the area's delegate
    /// makes one of it.
    private func open(_ drop: NSDraggingInfo, at index: Int) -> Bool {
        guard let item = tabViewItem(for: drop) else { return false }
        delegate?.editorGroupWasChosen(self)
        insertTabViewItem(item, at: index)
        return true
    }

    private func tabViewItem(for drop: NSDraggingInfo) -> NSTabViewItem? {
        delegate?.editorGroup(self, tabViewItemForDrop: drop)
    }

    func showDropHighlight(_ rect: NSRect?) {
        dropHighlight.isHidden = rect == nil
        guard let rect else { return }
        dropHighlight.frame = rect.insetBy(dx: 4, dy: 4)
    }
}

extension EditorGroupViewController: EditorTabBarDelegate {

    func tabBar(_ tabBar: EditorTabBar, didSelectTabAt index: Int) {
        delegate?.editorGroupWasChosen(self)
        selectedTabViewItemIndex = index
    }

    func tabBar(_ tabBar: EditorTabBar, didCloseTabAt index: Int) {
        guard tabViewItems.indices.contains(index) else { return }
        removeTabViewItem(tabViewItems[index])
    }

    func tabBar(_ tabBar: EditorTabBar, openDrop draggingInfo: NSDraggingInfo, at index: Int) -> Bool {
        open(draggingInfo, at: index)
    }

    /// Pins the temporary tab; a pinned tab stays pinned.
    func tabBar(_ tabBar: EditorTabBar, didDoubleClickTabAt index: Int) {
        guard tabViewItems.indices.contains(index), tabViewItems[index] === previewTabViewItem else { return }
        previewTabViewItem = nil
    }

    func tabBar(_ tabBar: EditorTabBar, didClickPinOfTabAt index: Int) {
        togglePinned(at: index)
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
        return delegate?.editorGroup(self, moveTabAt: index, of: sourceGroup, to: destination)
    }
}

/// What an editor has shown, as a browser's history: every entry in order and
/// the one it is at. Identifiers only — which tab shows an entry is the editor's
/// to find. An offset is a direction and a distance, back negative.
private struct History {

    private var entries: [AnyHashable] = []
    private var index = -1

    /// The entry `offset` from the current one, or `nil` past either end.
    func entry(at offset: Int) -> AnyHashable? {
        offset != 0 && entries.indices.contains(index + offset) ? entries[index + offset] : nil
    }

    /// `identifier` is shown now. Unless it is the current entry, that is a new
    /// step: it follows the current entry, and whatever lay ahead is gone.
    mutating func visit(_ identifier: AnyHashable) {
        guard entries.indices.contains(index) ? entries[index] != identifier : true else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(identifier)
        index += 1
    }

    /// Makes the entry `offset` along the current one.
    mutating func move(by offset: Int) {
        guard entry(at: offset) != nil else { return }
        index += offset
    }

    /// Forgets the entry `offset` along, keeping the current one current.
    mutating func remove(at offset: Int) {
        guard entry(at: offset) != nil else { return }
        entries.remove(at: index + offset)
        if offset < 0 { index -= 1 }
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

    private func drop(for sender: NSDraggingInfo) -> (rect: NSRect, perform: () -> Bool)? {
        let point = convert(sender.draggingLocation, from: nil)
        guard let source = sender.draggingSource as? EditorTabBar else {
            return group?.contentDrop(of: sender, at: point)
        }
        return group?.contentDrop(from: source, at: point).map { drop in
            (
                drop.rect,
                {
                    drop.perform()
                    return true
                }
            )
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = drop(for: sender)
        group?.showDropHighlight(drop?.rect)
        guard drop != nil else { return [] }
        return sender.draggingSource is EditorTabBar ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        group?.showDropHighlight(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        group?.showDropHighlight(nil)
        return drop(for: sender)?.perform() ?? false
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
