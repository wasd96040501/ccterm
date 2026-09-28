import AppKit

/// Editors side by side, each with its own tabs: the root of the tree.
///
/// ```
/// EditorAreaViewController      NSSplitViewController — the divider, and which editor is active
/// └─ EditorGroupViewController  one per editor — its tab bar, and an NSTabViewController
///    └─ NSViewController        one per tab — anything at all; this package never looks inside
/// ```
///
/// **The split is AppKit's.** An `NSSplitViewController` with a vertical divider:
/// dragging it, its cursor, its minimum widths and its accessibility come with
/// it. And so does something that matters for what the editors hold — a divider
/// drag is a *live resize* for every view under it, measured: each receives
/// `viewWillStartLiveResize()` and `viewDidEndLiveResize()`, and reports
/// `inLiveResize` for every frame in between, exactly as a window-edge drag does.
/// So a view that defers expensive work to the end of a live resize does it here
/// too, with nothing in this package having to know that it does.
///
/// **Two editors at most**, left and right. The area never has none: the last
/// editor stays when its last tab closes, and says so.
///
/// **Which editor is active** follows the reader — the one last clicked anywhere
/// inside, or holding the first responder — and is reported to the delegate
/// together with the tab that editor shows. It is what a window's commands aim
/// at: ⌘F, a new tab, a tool acting on "this transcript".
///
/// **The area answers its own commands** — `goBack(_:)`, `goForward(_:)`,
/// `closeTab(_:)` — as responder actions aimed at the active editor, and
/// validates them. A host puts them on a menu or a toolbar and implements none
/// of them.
@MainActor
public final class EditorAreaViewController: NSSplitViewController {

    static let maximumNumberOfGroups = 2

    /// Narrow enough to keep two editors on a laptop, wide enough that a tab bar
    /// still reads as one.
    static let minimumGroupWidth: CGFloat = 240

    public weak var delegate: EditorAreaViewControllerDelegate?

    /// The editor the reader is working in. Never `nil`: there is always one.
    public private(set) var activeGroup: EditorGroupViewController

    private weak var reportedViewController: NSViewController?
    private var hasReported = false

    private var mouseDownMonitor: Any?
    private var firstResponderObservation: NSKeyValueObservation?

    public init() {
        activeGroup = EditorGroupViewController()
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(Self.splitViewItem(for: activeGroup))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        startFollowingTheReader()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        stopFollowingTheReader()
    }

    private static func splitViewItem(for group: EditorGroupViewController) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: group)
        item.minimumThickness = minimumGroupWidth
        item.canCollapse = false
        return item
    }

    // MARK: - Editors

    /// Left to right.
    public var groups: [EditorGroupViewController] {
        splitViewItems.compactMap { $0.viewController as? EditorGroupViewController }
    }

    /// The selected tab of the active editor.
    public var activeViewController: NSViewController? { activeGroup.selectedViewController }

    /// Opens a second editor on the right showing `item`, and makes it active.
    /// Answers `nil`, and does nothing, when there are already two.
    @discardableResult
    public func addGroup(with item: NSTabViewItem) -> EditorGroupViewController? {
        guard let group = addGroup() else { return nil }
        group.addTabViewItem(item)
        return group
    }

    /// Closes every tab of `group` — each one reported through
    /// `editorArea(_:willClose:)` — which closes the editor itself unless it is
    /// the only one.
    public func removeGroup(_ group: EditorGroupViewController) {
        for item in group.tabViewItems.reversed() {
            group.removeTabViewItem(item)
        }
    }

    /// Selects the open tab whose `NSTabViewItem.identifier` equals `identifier`
    /// (compared as `AnyHashable`, as the history compares them), in whichever
    /// editor has it, and answers whether there was one. The active editor stays
    /// where the reader is: the tab is brought forward in its own editor.
    @discardableResult
    public func selectTabViewItem(withIdentifier identifier: Any) -> Bool {
        guard let identifier = identifier as? AnyHashable else { return false }
        for group in groups {
            guard let index = group.tabViewItems.firstIndex(where: { $0.identifier as? AnyHashable == identifier })
            else { continue }
            group.selectedTabViewItemIndex = index
            return true
        }
        return false
    }

    /// Lets things of `types` be dropped on the editors — beside tabs dragged
    /// between them, which need nothing registered. The delegate names what each
    /// drop shows in `editorArea(_:identifierForDrop:)` and makes its tab in
    /// `editorArea(_:tabViewItemWithIdentifier:)`.
    public func registerForDraggedTypes(_ types: [NSPasteboard.PasteboardType]) {
        draggedTypes = types
        groups.forEach { $0.acceptDrops(of: types) }
    }

    private(set) var draggedTypes: [NSPasteboard.PasteboardType] = []

    private func addGroup() -> EditorGroupViewController? {
        guard groups.count < Self.maximumNumberOfGroups else { return nil }
        let group = EditorGroupViewController()
        addSplitViewItem(Self.splitViewItem(for: group))
        // Halves, the way Xcode opens one. Laid out first so the divider has a
        // width to be put in the middle of.
        if isViewLoaded {
            view.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
        activeGroup = group
        return group
    }

    /// Every editor coming passes through here — `addSplitViewItem` and setting
    /// `splitViewItems` included — reports to the area, and takes what it takes.
    public override func insertSplitViewItem(_ splitViewItem: NSSplitViewItem, at index: Int) {
        super.insertSplitViewItem(splitViewItem, at: index)
        guard let group = splitViewItem.viewController as? EditorGroupViewController else { return }
        group.delegate = self
        if !draggedTypes.isEmpty { group.acceptDrops(of: draggedTypes) }
    }

    /// Makes `group` the active editor.
    func activate(_ group: EditorGroupViewController) {
        guard groups.contains(where: { $0 === group }) else { return }
        activeGroup = group
        reportActiveViewController()
    }

    private func reportActiveViewController() {
        let current = activeViewController
        guard !hasReported || current !== reportedViewController else { return }
        hasReported = true
        reportedViewController = current
        delegate?.editorArea(self, didActivate: current)
    }

    // MARK: - Commands

    /// Xcode's ⌘W: closes the active editor's selected tab, or the window when
    /// there is no tab to close. A standard responder action, so a nil-targeted
    /// menu item finds it from anything inside the area.
    @objc public func closeTab(_ sender: Any?) {
        guard let item = activeGroup.selectedTabViewItem else {
            view.window?.performClose(sender)
            return
        }
        activeGroup.removeTabViewItem(item)
    }

    /// Back through the active editor's history — a toolbar's back button.
    @objc public func goBack(_ sender: Any?) {
        activeGroup.goBack()
    }

    /// Forward through the active editor's history — a toolbar's forward button.
    @objc public func goForward(_ sender: Any?) {
        activeGroup.goForward()
    }

    /// Back and forward while the active editor has somewhere to go; Close Tab
    /// while there is a tab or a window to close. Menu items and toolbar items
    /// (through `validateToolbarItem(_:)`) alike are asked here, after every event.
    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return activeGroup.canGoBack
        case #selector(goForward(_:)): return activeGroup.canGoForward
        case #selector(closeTab(_:)): return activeGroup.selectedTabViewItem != nil || view.window != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - Moving tabs between editors

    /// Moves the tab at `index` of `source` into `destination` at `position`,
    /// selected there, with the destination made active. Answers where it landed.
    @discardableResult
    func moveTab(
        at index: Int, of source: EditorGroupViewController,
        to destination: EditorGroupViewController, at position: Int
    ) -> Int {
        let landed = destination.attach(source.detach(at: index), at: position)
        activeGroup = destination
        // The destination first: if the source emptied and closes, the active
        // editor is already the one that took the tab.
        destination.tabsDidChange()
        source.tabsDidChange()
        return landed
    }

    /// Moves a tab to the other editor, opening one on the right if there is
    /// only this one. Refused for an editor's only tab when it is the only
    /// editor: that would leave it empty and closing — the same layout, moved
    /// over.
    func moveTabToOtherGroup(at index: Int, of source: EditorGroupViewController) {
        guard groups.count > 1 || source.tabViewItems.count > 1,
            let destination = groups.first(where: { $0 !== source }) ?? addGroup()
        else { return }
        moveTab(at: index, of: source, to: destination, at: destination.tabViewItems.count)
    }

    // MARK: - Following the reader

    /// Two signals, because neither covers the other. A click on something that
    /// never takes the focus — a transcript's blank margin, a picture — changes no
    /// first responder, and moving the focus with Tab involves no click.
    ///
    /// The mouse is watched with a local monitor rather than by overriding
    /// `mouseDown` on the editors: an event goes to the deepest view under it and
    /// stops there, so an editor would never see the clicks its own content takes.
    /// The monitor only looks; the event goes on unchanged.
    private func startFollowingTheReader() {
        guard mouseDownMonitor == nil, let window = view.window else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.activateGroup(under: event) }
            return event
        }
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) {
            [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let responder = window.firstResponder as? NSView,
                    let group = self.groups.first(where: { responder.isDescendant(of: $0.view) })
                else { return }
                self.activate(group)
            }
        }
    }

    private func stopFollowingTheReader() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        firstResponderObservation = nil
    }

    private func activateGroup(under event: NSEvent) {
        guard event.window === view.window,
            let group = groups.first(where: {
                $0.view.bounds.contains($0.view.convert(event.locationInWindow, from: nil))
            })
        else { return }
        activate(group)
    }
}

extension EditorAreaViewController: EditorGroupViewControllerDelegate {

    func editorGroupWasChosen(_ group: EditorGroupViewController) {
        activate(group)
    }

    /// Closes an editor that ran out of tabs, unless it is the only one.
    func editorGroupDidChangeTabs(_ group: EditorGroupViewController) {
        if group.tabViewItems.isEmpty, groups.count > 1,
            let item = splitViewItems.first(where: { $0.viewController === group })
        {
            removeSplitViewItem(item)
            if activeGroup === group, let remaining = groups.first { activeGroup = remaining }
        }
        reportActiveViewController()
    }

    func editorGroup(_ group: EditorGroupViewController, willClose viewController: NSViewController) {
        delegate?.editorArea(self, willClose: viewController)
    }

    func editorGroup(
        _ group: EditorGroupViewController, tabViewItemWithIdentifier identifier: AnyHashable
    ) -> NSTabViewItem? {
        delegate?.editorArea(self, tabViewItemWithIdentifier: identifier.base)
    }

    func editorGroup(
        _ group: EditorGroupViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem? {
        guard let delegate, let identifier = delegate.editorArea(self, identifierForDrop: draggingInfo) else {
            return nil
        }
        return delegate.editorArea(self, tabViewItemWithIdentifier: identifier)
    }

    func position(of group: EditorGroupViewController) -> EditorGroupViewController.Position {
        guard groups.count > 1 else { return .only }
        return groups.first === group ? .left : .right
    }

    func editorGroup(
        _ group: EditorGroupViewController, moveTabAt index: Int, of source: EditorGroupViewController,
        to position: Int
    ) -> Int {
        moveTab(at: index, of: source, to: group, at: position)
    }

    func editorGroup(_ group: EditorGroupViewController, moveTabToOtherGroupAt index: Int) {
        moveTabToOtherGroup(at: index, of: group)
    }

    func editorGroup(_ group: EditorGroupViewController, openNewGroupWith item: NSTabViewItem) {
        addGroup(with: item)
    }
}

/// A toolbar item asks its target `validateToolbarItem(_:)` and nothing else —
/// measured: without this, an item aimed at the area stays enabled whatever
/// `validateUserInterfaceItem(_:)` answers. So it is passed to the one switch
/// menu items are asked.
extension EditorAreaViewController: NSToolbarItemValidation {
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validateUserInterfaceItem(item)
    }
}
