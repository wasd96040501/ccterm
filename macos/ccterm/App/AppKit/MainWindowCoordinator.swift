import AppKit
import Combine

/// Window-scope coordinator. Owns the `MainWindowController` +
/// `MainSplitViewController` + `SidebarViewController`; delegates the
/// detail-side flow to a child `DetailFlowCoordinator`. This is the one
/// place that turns "user did something in the sidebar or the toolbar"
/// into "mutate the `SelectionStore` and re-route detail" — the VCs
/// themselves report semantic events and know nothing about routing.
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
    private var cancellables: Set<AnyCancellable> = []

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
        let detailFlow = DetailFlowCoordinator(
            detailContext: DetailContext(app: appContext, selectionStore: selectionStore),
            container: detailContainer,
            sessionManager: appContext.sessionManager,
            notifications: appContext.notificationService)
        self.detailFlowCoordinator = detailFlow
        addChild(detailFlow)

        // Sync toolbar chrome from the initial selection so a first
        // launch that lands on `.newSession` renders without waiting
        // for a click.
        updateToolbarForSelection(selectionStore.selection)

        // Rebuild toolbar chrome on every selection change. Coordinators
        // don't `sink` on the store as a routing bus — this is a display
        // derivation sink for our own toolbar, mirroring the rule from
        // the root CLAUDE.md.
        selectionStore.$selection
            .sink { [weak self] newSelection in
                guard let self else { return }
                self.updateToolbarForSelection(newSelection)
            }
            .store(in: &cancellables)

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

    // MARK: - Toolbar derivation

    private func updateToolbarForSelection(_ selection: MainSelection) {
        // Project chip: show whenever a real history session is
        // selected; hide otherwise. Directory name comes from
        // `originPath.lastPathComponent`; branch name is a synchronous
        // git probe (falls back to `worktreeBranch` when the on-disk
        // repo can't be read — happens for stale sessions whose cwd
        // was moved).
        switch selection {
        case .session(let sid):
            let session = appContext.sessionManager.existingSession(sid)
            let dirName: String? = {
                guard let path = session?.originPath, !path.isEmpty else { return nil }
                let comp = (path as NSString).lastPathComponent
                return comp.isEmpty ? nil : comp
            }()
            let branchName: String? = {
                if let cwd = session?.cwd,
                    let probed = GitUtils.currentBranch(at: cwd),
                    !probed.isEmpty
                {
                    return probed
                }
                if let session, let b = session.worktreeBranch, !b.isEmpty { return b }
                return nil
            }()
            let vm = ProjectChipViewModel(directoryName: dirName, branchName: branchName)
            windowController.updateProjectChip(with: vm)
        case .none, .newSession, .archive:
            windowController.updateProjectChip(with: nil)
        }

        // Archive filter: only visible when the Archive tab is active.
        // Options come from the manager's derived list; the currently-
        // chosen path is a store field the coordinator wrote when the
        // user picked a folder in the popover.
        switch selection {
        case .archive:
            windowController.updateArchiveFilterPresence(
                show: true,
                options: appContext.sessionManager.archivedFolderOptions,
                selectedPath: selectionStore.archiveSelectedFolderPath)
        case .none, .newSession, .session:
            windowController.updateArchiveFilterPresence(
                show: false, options: [], selectedPath: nil)
        }
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
        // Route the query into whichever session's controller is
        // currently on-screen. `.newSession` and `.archive` selections
        // have no transcript controller, so those are no-ops.
        guard let sid = selectionStore.effectiveSessionId else { return }
        let controller = appContext.sessionManager.existingSession(sid)?.controller
        controller?.runSearch(query)
    }

    func mainWindowController(
        _ controller: MainWindowController,
        searchDidRequestNext shift: Bool
    ) {
        // `shift == true` → next hit; `shift == false` → previous hit.
        guard let sid = selectionStore.effectiveSessionId else { return }
        let controller = appContext.sessionManager.existingSession(sid)?.controller
        if shift {
            controller?.nextSearchHit()
        } else {
            controller?.previousSearchHit()
        }
    }

    func mainWindowController(
        _ controller: MainWindowController,
        archiveFilterDidSelectFolderPath path: String?
    ) {
        selectionStore.setArchiveFolder(path)
        // The toolbar reflects the just-picked filter immediately so
        // the button's filled/unfilled state updates without waiting on
        // the display sink. The overall selection is still `.archive`
        // (unchanged), so `$selection` won't fire on its own.
        updateToolbarForSelection(selectionStore.selection)
    }
}
