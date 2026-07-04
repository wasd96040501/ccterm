import AppKit

/// Two-item `NSSplitViewController` — the AppKit-native sidebar on the
/// leading side and the `DetailContainerViewController` (a dumb single-
/// child swap slot, populated by `DetailFlowCoordinator`) on the
/// trailing side.
///
/// Both children are handed in fully-constructed — the split VC owns
/// **containment** but not **assembly**: the `MainWindowCoordinator`
/// wires the sidebar's context / delegate and the detail flow before
/// this VC exists, so nothing here reaches into the DI graph.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let sidebarViewController: SidebarViewController
    let detailContainer: DetailContainerViewController

    init(sidebar: SidebarViewController, detail: DetailContainerViewController) {
        self.sidebarViewController = sidebar
        self.detailContainer = detail
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        super.loadView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        // First-launch width when no autosaved divider position exists.
        // 0.22 of a 1200pt default window → 264pt, inside [220, 350].
        // Once autosave kicks in this is ignored.
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .automatic
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.minimumThickness = 680
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        // Persist the user's divider position (and collapsed state)
        // across launches. Set after both items are added — AppKit
        // restores the saved frames on the next layout pass.
        splitView.autosaveName = "ccterm.mainSplit"
    }

    nonisolated deinit {}
}
