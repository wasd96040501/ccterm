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

    /// Lets things of `types` be dropped on the editors — beside tabs dragged
    /// between them, which need nothing registered. The delegate makes each
    /// drop's tab in `editorArea(_:tabViewItemForDrop:)`.
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
    /// `splitViewItems` included — and takes what the area takes.
    public override func insertSplitViewItem(_ splitViewItem: NSSplitViewItem, at index: Int) {
        super.insertSplitViewItem(splitViewItem, at: index)
        if !draggedTypes.isEmpty {
            (splitViewItem.viewController as? EditorGroupViewController)?.acceptDrops(of: draggedTypes)
        }
    }

    /// Makes `group` the active editor.
    func activate(_ group: EditorGroupViewController) {
        guard groups.contains(where: { $0 === group }) else { return }
        activeGroup = group
        reportActiveViewController()
    }

    /// Called by a group after every change to its tabs.
    func groupDidChangeTabs(_ group: EditorGroupViewController) {
        if group.tabViewItems.isEmpty, groups.count > 1,
            let item = splitViewItems.first(where: { $0.viewController === group })
        {
            removeSplitViewItem(item)
            if activeGroup === group, let remaining = groups.first { activeGroup = remaining }
        }
        reportActiveViewController()
    }

    private func reportActiveViewController() {
        let current = activeViewController
        guard !hasReported || current !== reportedViewController else { return }
        hasReported = true
        reportedViewController = current
        delegate?.editorArea(self, didActivate: current)
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
    /// only this one.
    func moveTabToOtherGroup(at index: Int, of source: EditorGroupViewController) {
        guard canMoveTab(outOf: source),
            let destination = groups.first(where: { $0 !== source }) ?? addGroup()
        else { return }
        moveTab(at: index, of: source, to: destination, at: destination.tabViewItems.count)
    }

    /// Whether a tab can leave `group` for the other editor. Moving an editor's
    /// only tab into a new editor beside it would leave the first one empty and
    /// closing — the same layout, moved over — so that one is refused.
    func canMoveTab(outOf group: EditorGroupViewController) -> Bool {
        groups.count > 1 || group.tabViewItems.count > 1
    }

    /// What the tab menu calls moving a tab out of `group`.
    func moveMenuTitle(forTabIn group: EditorGroupViewController) -> String? {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return nil }
        if groups.count == 1 { return String(localized: "Move to New Editor on Right", bundle: .module) }
        return index == 0
            ? String(localized: "Move to Editor on Right", bundle: .module)
            : String(localized: "Move to Editor on Left", bundle: .module)
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
