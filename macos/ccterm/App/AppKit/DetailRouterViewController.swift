import AppKit
import Observation

/// Empty AppKit container at the detail slot of `MainSplitViewController`.
/// Hosts exactly one child `NSViewController` at a time and swaps it on
/// `MainSelectionModel.selection` changes through proper AppKit VC
/// containment (`addChild` / `removeFromParent` + `view.addSubview` /
/// `removeFromSuperview`).
///
/// The router's purpose is to **let each selection have its own VC**,
/// instead of cramming archive / demos / chat / compose into one
/// always-mounted detail VC and toggling them via overlay opacity +
/// hit-test heuristics. Pre-router, that single-VC design forced
/// `PassthroughHostingView`'s wrong "is super.hitTest === self" gate to
/// exist (which then silently dropped clicks on every plain-style
/// SwiftUI button in the input bar's chrome row).
///
/// ## Scaffolding state (this commit)
///
/// Only one child kind is plumbed: `.transcript` →
/// `TranscriptDetailViewController`. Every selection currently routes
/// to it, so the router never actually swaps children yet — but the
/// observation + swap machinery is in place. Subsequent commits on
/// this PR pull `.archive` and `.demo(_)` out of
/// `TranscriptDetailViewController` and into their own kinds here, at
/// which point a sidebar click really does tear the old child VC down
/// and instantiate the new one from scratch.
///
/// `DetailRouterContainmentTests` pins the invariant that there is
/// always exactly one child and it stays attached to `view` — the
/// regression gate for every later extraction.
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
        // `.archive` and `.demo(_)` arrive in follow-up commits as
        // they're extracted out of `TranscriptDetailViewController`.
    }

    /// Pure routing decision: which kind of child VC `selection`
    /// should map to. Static + pure so the routing table is directly
    /// unit-testable — see `DetailRouterContainmentTests`.
    static func childKind(for selection: MainSelection) -> ChildKind {
        // Scaffolding: every selection routes through
        // `TranscriptDetailViewController` for now. As `.archive` and
        // `.demo(_)` get their own VCs, they'll get their own cases
        // here and the swap below will start firing.
        switch selection {
        case .none, .newSession, .session, .archive:
            return .transcript
        #if DEBUG
        case .demo:
            return .transcript
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
            return TranscriptDetailViewController(
                model: model,
                sessionManager: sessionManager,
                recentProjects: recentProjects,
                notifications: notifications,
                searchEngine: searchEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore
            )
        }
    }

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
