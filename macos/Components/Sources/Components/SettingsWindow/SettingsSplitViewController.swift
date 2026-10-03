import AppKit

/// The Settings window's content: the pane list beside the shown pane, with
/// back and forward through the panes visited.
///
/// The sidebar is 180 wide and stays so — it neither collapses nor resizes,
/// as in System Settings. The panes are children of an `NSTabViewController`
/// with no tabs of its own, which shows one at a time.
public final class SettingsSplitViewController: NSSplitViewController {
    /// A page of the window: its row in the sidebar, and what it shows.
    public struct Pane {
        public var title: String
        /// The sidebar's glyph: the design's, a template image (`NSImage.settingsGear`).
        public var glyph: NSImage
        public var viewController: NSViewController

        public init(title: String, glyph: NSImage, viewController: NSViewController) {
            self.title = title
            self.glyph = glyph
            self.viewController = viewController
        }
    }

    weak var delegate: SettingsSplitViewControllerDelegate?

    private let items: [Pane]
    private var history: SettingsHistory

    private let sidebar: SettingsSidebarViewController
    private let panes = NSTabViewController()

    /// `initial`: the index of the pane shown first.
    public init(panes: [Pane], initial: Int) {
        items = panes
        history = SettingsHistory(initial)
        sidebar = SettingsSidebarViewController(panes: panes)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The sidebar's width, fixed.
    static let sidebarWidth: CGFloat = 180

    public override func loadView() {
        super.loadView()
        panes.tabStyle = .unspecified
        panes.transitionOptions = []
        for pane in items {
            let item = NSTabViewItem(viewController: pane.viewController)
            item.label = pane.title
            panes.addTabViewItem(item)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: panes)
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)
        splitView.dividerStyle = .thin
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.delegate = self
        show(history.current)
    }

    // MARK: - Navigation

    @objc func goBack(_ sender: Any?) {
        history.goBack()
        show(history.current)
    }

    @objc func goForward(_ sender: Any?) {
        history.goForward()
        show(history.current)
    }

    private func show(_ index: Int) {
        panes.selectedTabViewItemIndex = index
        sidebar.select(index)
        delegate?.settingsSplitViewController(self, didShow: items[index])
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        default: super.validateUserInterfaceItem(item)
        }
    }

    /// Menu actions the responder chain doesn't take — ⌘V with the sidebar
    /// focused — go to the shown pane when it handles them.
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        let pane = panes.tabViewItems[panes.selectedTabViewItemIndex].viewController
        if let pane, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: - NSSplitViewDelegate

    /// No divider to drag: the sidebar's width is fixed.
    public override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        .zero
    }
}

extension SettingsSplitViewController: SettingsSidebarViewControllerDelegate {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect pane: Int) {
        history.go(to: pane)
        show(history.current)
    }
}
