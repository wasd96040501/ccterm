import AppKit

/// Two-item `NSSplitViewController` that hosts the AppKit-native
/// `SidebarViewController` on the leading side and the
/// AppKit-rooted `TranscriptDetailViewController` on the trailing side.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let model: MainSelectionModel
    let appState: AppState
    let searchBus: TranscriptSearchBus

    let detailViewController: TranscriptDetailViewController
    private let sidebarViewController: SidebarViewController

    init(model: MainSelectionModel, appState: AppState, searchBus: TranscriptSearchBus) {
        self.model = model
        self.appState = appState
        self.searchBus = searchBus

        sidebarViewController = SidebarViewController(
            model: model, sessionManager: appState.sessionManager)

        detailViewController = TranscriptDetailViewController(
            model: model,
            sessionManager: appState.sessionManager,
            recentProjects: appState.recentProjects,
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
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .automatic
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 680
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
    }
}
