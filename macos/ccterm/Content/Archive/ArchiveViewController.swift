import AppKit
import SwiftUI

/// AppKit container that mounts the SwiftUI `ArchiveView` as the
/// detail pane's content when the sidebar selection is `.archive`.
/// Owned by `DetailRouterViewController`; lives only while archive
/// is selected and is fully torn down on selection change (no
/// lingering subviews, no observation tasks left armed).
///
/// Wraps an `NSHostingController<AnyView>` so the SwiftUI tree is
/// hosted with proper child-VC plumbing — `NSHostingController`
/// forwards `viewDidLoad` / `viewWillAppear` / etc. into the SwiftUI
/// runtime, which `NSHostingView` alone does not.
@MainActor
final class ArchiveViewController: NSViewController {
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let searchEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    private var host: NSHostingController<AnyView>!

    init(
        model: MainSelectionModel,
        sessionManager: SessionManager,
        recentProjects: RecentProjectsStore,
        notifications: NotificationService,
        searchEngine: SyntaxHighlightEngine,
        searchBus: TranscriptSearchBus,
        inputDraftStore: InputDraftStore
    ) {
        self.model = model
        self.sessionManager = sessionManager
        self.recentProjects = recentProjects
        self.notifications = notifications
        self.searchEngine = searchEngine
        self.searchBus = searchBus
        self.inputDraftStore = inputDraftStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // `model.archiveSelectedFolderPath` is the source of truth —
        // the toolbar's folder-filter button writes to the same field,
        // so a two-way binding keeps the popover and the list in sync.
        let folderBinding = Binding<String?>(
            get: { [weak self] in self?.model.archiveSelectedFolderPath },
            set: { [weak self] in self?.model.archiveSelectedFolderPath = $0 }
        )

        let root = AnyView(
            ArchiveView(
                selectedFolderPath: folderBinding,
                onUnarchive: { [weak self] resumeSid in
                    self?.model.selection = .session(resumeSid)
                }
            )
            .environment(sessionManager)
            .environment(recentProjects)
            .environment(inputDraftStore)
            .environment(\.syntaxEngine, searchEngine)
            .environment(searchBus)
            .environment(notifications)
        )

        let host = NSHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.host = host
    }
}
