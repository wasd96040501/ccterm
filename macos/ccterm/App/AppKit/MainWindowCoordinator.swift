import AppKit

/// Window-scope coordinator. Owns the `MainWindowController` +
/// `MainSplitViewController` + `SidebarViewController`; delegates the
/// detail-side flow to a child `DetailFlowCoordinator`. This is the one
/// place that turns "user did something in the sidebar or the toolbar"
/// into "mutate the `SelectionStore` and re-route detail" — the VCs
/// themselves report semantic events and know nothing about routing.
///
/// **Never `sink` on the `SelectionStore`.** The store is a write-only
/// surface from this side of the loop; every display consumer that
/// needs to reflect the selection (sidebar highlight, toolbar chip /
/// archive-filter icon, …) subscribes to the store itself. Keeping the
/// coordinator sink-free is what preserves the single-writer discipline
/// documented in the root CLAUDE.md.
///
/// Retain topology per CLAUDE.md: parent strongly holds this via its
/// `childCoordinators` array; this coordinator holds `parent` weakly.
/// The window controller is the display half of this flow; when it
/// tells us "will close" we hand a completion note upward so the parent
/// can drop us from its children.
@MainActor
final class MainWindowCoordinator: Coordinator {
    let appContext: AppContext
    weak var parent: MainWindowCoordinatorParent?
    var childCoordinators: [Coordinator] = []

    let windowContext: WindowContext

    private let selectionStore: SelectionStore
    private let searchBus: SearchBusService
    private let detailContainer: DetailContainerViewController
    private let sidebarViewController: SidebarViewController
    private let splitViewController: MainSplitViewController
    private let windowController: MainWindowController

    private var detailFlowCoordinator: DetailFlowCoordinator?

    init(appContext: AppContext, parent: MainWindowCoordinatorParent?) {
        self.appContext = appContext
        self.parent = parent

        let selectionStore = SelectionStore()
        let searchBus = SearchBusService()
        self.selectionStore = selectionStore
        self.searchBus = searchBus
        self.windowContext = WindowContext(
            app: appContext, selectionStore: selectionStore, searchBus: searchBus)

        self.detailContainer = DetailContainerViewController()
        // Sidebar receives its selection delegate via a separate weak
        // argument (a `struct` context can't carry weak refs). The
        // coordinator is the delegate; sidebar mutations flow up here
        // before landing in the store.
        let sidebarVC = SidebarViewController(
            context: SidebarContext(
                selectionStore: selectionStore,
                sessionManager: appContext.sessionManager,
                groupOrderStore: appContext.sidebarGroupOrder,
                openInService: appContext.openInService))
        self.sidebarViewController = sidebarVC

        self.splitViewController = MainSplitViewController(
            sidebar: sidebarVC, detail: detailContainer)

        self.windowController = MainWindowController(
            windowContext: windowContext,
            splitViewController: splitViewController)

        // Delegates are wired after every field is populated so the
        // compiler-forced initialization order doesn't fight us.
        sidebarVC.selectionDelegate = self
        windowController.delegate = self
    }

    // MARK: - Coordinator

    func start() {
        // Detail-flow lifecycle rides as a child coordinator so its
        // teardown is deterministic: dropping this parent's ref
        // (`removeChild`) breaks the strong edge, and DetailFlow's own
        // `nonisolated deinit` finishes the tear.
        //
        // `addChild(_:)` only inserts into `childCoordinators` — starting
        // is the caller's responsibility, so "add" and "kick off" stay
        // two visible steps and no child gets started twice.
        let detailFlow = DetailFlowCoordinator(
            detailContext: DetailContext(app: appContext, selectionStore: selectionStore),
            container: detailContainer,
            sessionManager: appContext.sessionManager,
            notifications: appContext.notificationService)
        self.detailFlowCoordinator = detailFlow
        addChild(detailFlow)
        detailFlow.start()

        showMainWindow()
    }

    // MARK: - Public API (AppCoordinator surface)

    func showMainWindow() {
        windowController.showMainWindow()
    }

    /// Route a ⌘F request into the window's search bus. The window
    /// controller has its own sink on that subject and moves first
    /// responder to the search field.
    func requestSearchFocus() {
        searchBus.requestFocus()
    }

    nonisolated deinit {}
}

// MARK: - SidebarSelectionDelegate

extension MainWindowCoordinator: SidebarSelectionDelegate {
    func sidebar(
        _ sidebar: SidebarViewController,
        didSelect selection: MainSelection
    ) {
        // The detail coord internally mutates the `SelectionStore` and
        // mounts the correct child. We stay out of the way.
        detailFlowCoordinator?.route(to: selection)
    }
}

// MARK: - MainWindowControllerDelegate

extension MainWindowCoordinator: MainWindowControllerDelegate {
    func mainWindowControllerWillClose(_ controller: MainWindowController) {
        parent?.mainWindowCoordinatorDidFinish(self)
    }

    func mainWindowController(
        _ controller: MainWindowController,
        searchQueryDidChange query: String
    ) {
        // Transcript search is not wired to the flat history transcript
        // (the live render-side controller was removed). No-op for now.
    }

    func mainWindowController(
        _ controller: MainWindowController,
        searchDidRequestNext shift: Bool
    ) {
        // Transcript search is not wired to the flat history transcript
        // (the live render-side controller was removed). No-op for now.
    }

    func mainWindowController(
        _ controller: MainWindowController,
        archiveFilterDidSelectFolderPath path: String?
    ) {
        // Coordinator is the sole writer to `SelectionStore`. The
        // window controller's own sink on `$archiveSelectedFolderPath`
        // picks the change up and repaints the button icon in the same
        // source phase.
        selectionStore.setArchiveFolder(path)
    }
}
