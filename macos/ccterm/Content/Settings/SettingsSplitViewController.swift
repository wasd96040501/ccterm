import AppKit

/// The Settings window's content: the pane list beside the shown pane, with
/// back and forward through the panes visited.
///
/// The sidebar is 180 wide and stays so — it neither collapses nor resizes,
/// as in System Settings. The panes are children of an `NSTabViewController`
/// with no tabs of its own, which shows one at a time.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    weak var delegate: SettingsSplitViewControllerDelegate?

    private var history = SettingsHistory(.accounts)

    private let sidebar = SettingsSidebarViewController()
    private let panes = NSTabViewController()
    private let context: SettingsContext

    init(context: SettingsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The sidebar's width, fixed.
    static let sidebarWidth: CGFloat = 180

    override func loadView() {
        super.loadView()
        panes.tabStyle = .unspecified
        panes.transitionOptions = []
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: viewController(for: pane))
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

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.delegate = self
        show(history.current)
    }

    private func viewController(for pane: SettingsPane) -> NSViewController {
        switch pane {
        case .general:
            GeneralSettingsViewController(launch: context.launch)
        case .accounts:
            AccountsSettingsViewController(accounts: context.accounts, subscription: context.subscription)
        }
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

    private func show(_ pane: SettingsPane) {
        panes.selectedTabViewItemIndex = pane.rawValue
        sidebar.select(pane)
        delegate?.settingsSplitViewController(self, didShow: pane)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        default: super.validateUserInterfaceItem(item)
        }
    }

    /// Menu actions the responder chain doesn't take — ⌘V with the sidebar
    /// focused — go to the shown pane when it handles them.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        let pane = panes.tabViewItems[panes.selectedTabViewItemIndex].viewController
        if let pane, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: - NSSplitViewDelegate

    /// No divider to drag: the sidebar's width is fixed.
    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        .zero
    }
}

extension SettingsSplitViewController: SettingsSidebarViewControllerDelegate {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect pane: SettingsPane) {
        history.go(to: pane)
        show(history.current)
    }
}
