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
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let syntaxEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    private var host: NSHostingController<AnyView>!

    init(
        model: MainSelectionModel,
        sessionManager: SessionManager,
        recentProjects: RecentProjectsStore,
        notifications: NotificationService,
        syntaxEngine: SyntaxHighlightEngine,
        searchBus: TranscriptSearchBus,
        inputDraftStore: InputDraftStore
    ) {
        self.model = model
        self.sessionManager = sessionManager
        self.recentProjects = recentProjects
        self.notifications = notifications
        self.syntaxEngine = syntaxEngine
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
                    self?.model.select(.session(resumeSid))
                }
            )
            .environment(sessionManager)
            .environment(recentProjects)
            .environment(inputDraftStore)
            .environment(\.syntaxEngine, syntaxEngine)
        )

        let host = NSHostingController(rootView: root)
        // `NSHostingController`'s default `sizingOptions` binds the
        // SwiftUI body's fitting size into the hosting view's layout, so
        // `host.view.fittingSize` tracks the content's ideal size. That's
        // right for a standalone window's `contentViewController` (Settings
        // / About / Logs size to their content), but this host is a
        // fill-the-pane detail child: `ArchiveView`'s root is a `ScrollView`
        // whose fitting height is just the header (~176pt before the async
        // list lands). With the default options that small fitting height
        // bubbles up through the detail VC → the `NSSplitViewController`'s
        // `view.fittingSize`, and the window resizes its content down to it
        // — the whole window collapses to ~176pt the instant Archive is
        // selected (and stays collapsed when you switch back, since chat
        // contributes no fitting height to grow it again). Confirmed
        // offscreen: with the default, `host.view.fittingSize` ≈ 545×276;
        // cleared, it's 0×0 and the split fills the window. The pane must
        // take whatever height the window gives it via the 4-edge
        // constraints below — never drive it. `[]` matches `NSHostingView`'s
        // default, which the chat pane's compose host already relies on.
        host.sizingOptions = []
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
