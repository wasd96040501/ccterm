import AppKit

/// Two-item `NSSplitViewController` that hosts the AppKit-native
/// `SidebarViewController` on the leading side and a
/// `DetailRouterViewController` on the trailing side. The router
/// owns whichever detail child VC the current selection asks for —
/// see its doc comment for the scaffolding plan. Replaces
/// `RootView2`'s `NavigationSplitView` wrapper.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let model: MainSelectionModel
    let appState: AppState
    let searchBus: TranscriptSearchBus

    let detailRouter: DetailRouterViewController
    private let sidebarViewController: SidebarViewController

    init(model: MainSelectionModel, appState: AppState, searchBus: TranscriptSearchBus) {
        self.model = model
        self.appState = appState
        self.searchBus = searchBus

        sidebarViewController = SidebarViewController(
            model: model,
            sessionManager: appState.sessionManager,
            groupOrderStore: appState.sidebarGroupOrder,
            openInService: appState.openInService)

        detailRouter = DetailRouterViewController(
            model: model,
            sessionManager: appState.sessionManager,
            recentProjects: appState.recentProjects,
            remoteHosts: appState.remoteHosts,
            notifications: appState.notificationService,
            searchEngine: appState.syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: appState.inputDraftStore
        )

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

        let detailItem = NSSplitViewItem(viewController: detailRouter)
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
}
