import AppKit
import Observation
import SwiftUI

/// Empty AppKit container at the detail slot of `MainSplitViewController`.
/// Hosts exactly one child `NSViewController` at a time and swaps it on
/// `MainSelectionModel.selection` changes through proper AppKit VC
/// containment (`addChild` / `removeFromParent` + `view.addSubview` /
/// `removeFromSuperview`).
///
/// The router's purpose is to **let each selection have its own VC**,
/// instead of cramming archive / demos / chat / compose into one
/// always-mounted detail VC and toggling them via overlay opacity +
/// hit-test heuristics. The earlier single-VC shape was what forced
/// the now-deleted `PassthroughHostingView` and its "is super.hitTest
/// === self" gate to exist (which then silently dropped clicks on
/// every plain-style SwiftUI button in the input bar's chrome row).
///
/// Routing table:
/// - `.none` / `.newSession` / `.session(_)` → `ChatSessionViewController`
/// - `.archive` → `ArchiveViewController`
/// - `.demo(_)` (DEBUG only) → the matching demo VC
///
/// Same-kind transitions (e.g. flipping between two history sessions,
/// both `.transcript`) keep the existing child VC alive — the chat
/// VC's internal `attachSession` path handles the session swap. Only
/// cross-kind transitions tear down and rebuild.
///
/// `DetailRouterContainmentTests` pins the invariant that there is
/// always exactly one child and it stays attached to `view` — the
/// regression gate for the whole refactor.
@MainActor
final class DetailRouterViewController: NSViewController {
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let searchEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    /// The kind of VC currently mounted as the single child. Compared
    /// against `childKind(for:)` on selection change to decide whether
    /// a swap is needed — same-kind transitions (e.g. flipping between
    /// two history sessions, both `.transcript`) keep the existing
    /// child VC alive so its internal `attachSession` path can take
    /// over without paying for a full tree rebuild.
    private(set) var currentKind: ChildKind?

    /// The single mounted child. `private(set)` so containment tests
    /// can read it without widening the swap API.
    private(set) var currentChild: NSViewController?

    private var selectionObservationTask: Task<Void, Never>?

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

    deinit { selectionObservationTask?.cancel() }

    override func loadView() {
        // Plain container — the actual content comes from whichever
        // child VC is currently installed.
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installChildForCurrentSelection()
        startSelectionObservation()
    }

    // MARK: - Routing

    enum ChildKind: Equatable {
        case transcript
        case archive
        #if DEBUG
        case demo(DemoKind)
        #endif
    }

    /// Pure routing decision: which kind of child VC `selection`
    /// should map to. Static + pure so the routing table is directly
    /// unit-testable — see `DetailRouterContainmentTests`.
    static func childKind(for selection: MainSelection) -> ChildKind {
        switch selection {
        case .none, .newSession, .session:
            return .transcript
        case .archive:
            return .archive
        #if DEBUG
        case .demo(let kind):
            return .demo(kind)
        #endif
        }
    }

    /// Sync entry point used by both the observation hop and unit
    /// tests. Idempotent when the kind is unchanged.
    func installChildForCurrentSelection() {
        let kind = Self.childKind(for: model.selection)
        if kind == currentKind, currentChild != nil { return }

        if let old = currentChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let child = makeChild(for: kind)
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        currentKind = kind
        currentChild = child
    }

    private func makeChild(for kind: ChildKind) -> NSViewController {
        switch kind {
        case .transcript:
            return ChatSessionViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        case .archive:
            return ArchiveViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        #if DEBUG
        case .demo(let demoKind):
            return makeDemoChild(demoKind)
        #endif
        }
    }

    #if DEBUG
    private func makeDemoChild(_ kind: DemoKind) -> NSViewController {
        switch kind {
        case .transcript:
            return TranscriptDemoViewController(syntaxEngine: searchEngine)
        case .transcriptStress:
            return TranscriptStressViewController(syntaxEngine: searchEngine)
        case .transcriptPerf:
            return TranscriptPerfDemoViewController(syntaxEngine: searchEngine)
        case .permissionSession:
            return PermissionSessionDemoViewController(syntaxEngine: searchEngine)
        case .permissionCards:
            // The only demo that's a pure SwiftUI view — host it via
            // `NSHostingController` so the surrounding `addChild`
            // plumbing matches the other branches. Same environment
            // injections the production app uses.
            let root = AnyView(
                PermissionCardsDemoView()
                    .environment(sessionManager)
                    .environment(recentProjects)
                    .environment(inputDraftStore)
                    .environment(\.syntaxEngine, searchEngine)
                    .environment(searchBus)
                    .environment(notifications)
            )
            return NSHostingController(rootView: root)
        }
    }
    #endif

    // MARK: - Observation

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.selection
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.installChildForCurrentSelection()
            self.startSelectionObservation()
        }
    }
}
