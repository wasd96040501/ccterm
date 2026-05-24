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
/// - `.none` / `.session(_)` → `ChatSessionViewController`
/// - `.newSession` → `ComposeSessionViewController`
/// - `.archive` → `ArchiveViewController`
/// - `.demo(_)` (DEBUG only) → the matching demo VC
///
/// Same-kind transitions (e.g. flipping between two history sessions,
/// both `.transcript`) keep the existing child VC alive — the router
/// drives the child's imperative `present(sessionId:)` to swap the
/// session. Only cross-kind transitions tear down and rebuild.
///
/// ## Sole structural owner of the detail-side transition
///
/// The router is the **only** observer of `MainSelectionModel` for
/// structural purposes — it registers as the model's
/// `selectionObserver` and is driven **synchronously** from
/// `select(_:)`, in the same source phase as the click. It then:
///
/// 1. installs the correct child VC kind (swap only on cross-kind), and
/// 2. for the transcript kind, settles the child's frame and calls
///    `ChatSessionViewController.present(sessionId:)`.
///
/// This collapses what used to be two independent async observers (the
/// router AND the chat VC each watching `model.selection` on separate
/// `withObservationTracking` re-arm hops) into one synchronous path, so
/// "show session X" lands atomically rather than fragmenting across
/// ticks. The chat VC no longer observes selection at all.
///
/// `DetailRouterContainmentTests` pins the invariant that there is
/// always exactly one child and it stays attached to `view` — the
/// regression gate for the whole refactor.
@MainActor
final class DetailRouterViewController: NSViewController, MainSelectionObserver {
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
    /// child VC alive, and the router hands it the new session via
    /// `present(sessionId:)` without paying for a full tree rebuild.
    private(set) var currentKind: ChildKind?

    /// The single mounted child. `private(set)` so containment tests
    /// can read it without widening the swap API.
    private(set) var currentChild: NSViewController?

    /// Gates the first transcript attach until the router's view has a
    /// real frame. The router's `viewDidLoad` runs before the split has
    /// sized the detail item, so the very first `applySelection` (which
    /// runs `layoutSubtreeIfNeeded` + the child's `present`) is deferred
    /// to the first framed `viewDidLayout`. Every selection change after
    /// that is applied synchronously from `selectionDidChange(to:)`.
    private var didInitialApply = false

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
        // Plain container — the actual content comes from whichever
        // child VC is currently installed.
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Become the model's sole structural observer — `select(_:)`
        // now drives `selectionDidChange(to:)` synchronously.
        model.selectionObserver = self
        // Own the app→detail signals that used to be observed by every
        // (leaky) `ChatSessionViewController`: a notification click maps
        // straight to a selection change. The router is the single,
        // window-lifetime owner, so there's exactly one consumer and no
        // per-detail-VC observation task to retain a torn-down VC.
        notifications.onActivateSession = { [weak self] sid in
            self?.model.select(.session(sid))
        }
        // Notification subsystem bootstrap, kicked once per main-window
        // mount from the stable owner. `bootstrap()` guards re-entry.
        notifications.bootstrap()
        // Mount the correct child VC kind for the initial selection. The
        // transcript attach itself rides the first framed `viewDidLayout`
        // (the view has no real frame yet here).
        installChildForCurrentSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // First framed pass: run the full transition (child kind is
        // already mounted; this adds the transcript attach against the
        // now-settled frame). Subsequent changes come through
        // `selectionDidChange(to:)` synchronously.
        guard !didInitialApply, view.bounds.width > 0, view.bounds.height > 0 else { return }
        didInitialApply = true
        applySelection(model.selection)
    }

    // MARK: - Routing

    enum ChildKind: Equatable {
        case transcript
        case compose
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
        case .none, .session:
            return .transcript
        case .newSession:
            return .compose
        case .archive:
            return .archive
        #if DEBUG
        case .demo(let kind):
            return .demo(kind)
        #endif
        }
    }

    /// Ensure the correct child VC **kind** is mounted for the current
    /// selection — swap only on a cross-kind change, reuse otherwise.
    /// Does NOT attach a session; the transcript attach is driven
    /// separately by `applySelection` via `present(sessionId:)`. Called
    /// from `applySelection` and directly by `DetailRouterContainmentTests`
    /// (which assert tree shape without a window). Idempotent when the
    /// kind is unchanged.
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
        case .compose:
            return ComposeSessionViewController(
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
            let host = NSHostingController(rootView: root)
            // Fill-the-pane detail child — clear `sizingOptions` so the
            // SwiftUI body's fitting size doesn't bubble up through the
            // split's `view.fittingSize` and collapse the window height
            // (see `ArchiveViewController` for the full rationale). The
            // router pins this view to the detail slot.
            host.sizingOptions = []
            return host
        }
    }
    #endif

    // MARK: - Selection transition (synchronous)

    /// `MainSelectionObserver` — driven synchronously from
    /// `MainSelectionModel.select(_:)`, in the same source phase as the
    /// caller (a sidebar click, a notification activation, etc).
    func selectionDidChange(to selection: MainSelection) {
        // Before the first framed layout there is nothing to attach a
        // transcript to — just keep the child kind in sync; the initial
        // `applySelection` rides `viewDidLayout`.
        guard isViewLoaded else { return }
        guard didInitialApply else {
            installChildForCurrentSelection()
            return
        }
        applySelection(selection)
    }

    /// The whole detail-side transition in one synchronous pass:
    /// install the correct child VC kind (swap only on cross-kind),
    /// then — for the transcript kind — settle the child's frame and
    /// hand it the new session imperatively. Compose / archive / demo
    /// children manage their own content, so the router stops at the
    /// child swap for them.
    private func applySelection(_ selection: MainSelection) {
        installChildForCurrentSelection()
        guard Self.childKind(for: selection) == .transcript else { return }
        // Settle the freshly-(re)mounted child so the transcript attach
        // typesets at the final width (the §2.19 single-width contract).
        view.layoutSubtreeIfNeeded()
        let sessionId: String?
        if case .session(let sid) = selection { sessionId = sid } else { sessionId = nil }
        (currentChild as? ChatSessionViewController)?.present(sessionId: sessionId)
    }
}
