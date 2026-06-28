import AgentSDK
import AppKit
import Combine
import Observation
import SwiftUI

/// Child VC the `DetailRouterViewController` mounts for chat-bearing
/// selections (`.session(_)` / `.none`). Owns the transcript
/// `Transcript2ScrollView` directly — created in `loadView()` so the
/// table's mount + `frameDidChange` cascade lives in AppKit's source
/// phase, not in SwiftUI's commit pass (the whole point of #195).
///
/// This VC does **not** observe `MainSelectionModel`. The router is the
/// sole structural owner and drives the session swap imperatively via
/// `present(sessionId:)` — called synchronously once this VC is mounted
/// AND framed, so the attach always runs against a settled frame (no
/// deferred-attach machinery) and lands in the same source phase as the
/// click that triggered it.
///
/// New Session (`.newSession`) is NOT handled here — it has its own
/// `ComposeSessionViewController`. That split is deliberate: when
/// compose and chat shared this VC's one always-mounted bar host, the
/// host had to morph between full-bleed (compose) and bottom-anchored
/// (chat), and the constraint switch couldn't stay in sync with the
/// SwiftUI body across runloop phases — the full-bleed host lingered
/// over the transcript after a fast switch and swallowed its clicks.
/// With compose gone, the bar host here is *always* bottom-anchored
/// and only ever renders the chat resting bar (or nothing for `.none`),
/// so it never covers more of the transcript than the bar itself.
///
/// Around the transcript we mount two overlays, both attached for the
/// lifetime of the VC; their *contents* react to `model.selection`:
/// - top scrim — `TranscriptTopScrimView` (AppKit, hitTest passthrough;
///   the top band doubles as the title-bar drag/zoom region, which has no
///   SwiftUI equivalent, so it stays pure AppKit).
/// - bottom cluster — `bottomClusterHost` (`NSHostingView<ChatBottomClusterRoot>`),
///   a single **full-width, bottom-anchored, content-height** host holding
///   one merged SwiftUI tree: the fade gradient, the input bar, and the
///   floating permission card, composited bottom-to-top in one `ZStack`.
///   Its SwiftUI body switches on `model.selection` via
///   `ChatBottomCluster.content(...)`: `.session(_)` → bar + card,
///   everything else → `EmptyView`. `.newSession` / `.archive` / `.demo(_)`
///   are routed away from this VC entirely by `DetailRouterViewController`
///   and never land here.
///
/// The cluster host's top edge floats at `view.bottom − cluster height`, so
/// it covers only the bottom band (fade + bar + card). The transcript scroll
/// view above it stays fully uncovered and receives clicks / selection there
/// — a plain `NSHostingView` is non-occluding by *geometry*, not by any
/// hit-test trick. The bottom band itself is intentionally not selectable
/// (the merged tree draws opaque bar/card in front of a decorative fade), so
/// there is no scrim "hole" to cut and no click-through hack: clicks inside
/// the card reach the card's buttons; clicks in the fade band are absorbed by
/// the host.
@MainActor
final class ChatSessionViewController: NSViewController, DetailRouterChild {
    /// Top fade band height. Sized to match the unified toolbar so the
    /// gradient fades in exactly the strip the toolbar visually covers.
    private static let topFadeScrimHeight: CGFloat = 52
    /// Bottom fade band height. Sized to match the input bar's top
    /// edge, so the gradient stops where the bar begins. Derived from
    /// `chatBottomInset` (36) + `InputBarSessionChrome` row (~22) +
    /// `InputBarSessionChrome.barSpacing` (10) + `InputBarView2` pill
    /// (32) = 100. Hardcoded — those constants don't change at runtime.
    /// Read by `ChatBottomCluster` to size the fade layer.
    static let bottomFadeScrimHeight: CGFloat = 100
    static let composeMaxWidth: CGFloat = 512
    static let chatBottomInset: CGFloat = 36
    static let detailHorizontalInset: CGFloat = 20
    static let detailVerticalInset: CGFloat = 20

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// Owns the transcript-swap state machine (build / bind / anchor /
    /// crossfade / tear-down + the per-attach turn-usage + `isRunning`
    /// sinks). The VC keeps "what the pane shows" (top scrim, bottom
    /// cluster, focus); the coordinator owns the transcript-attach
    /// mechanism and is the single owner of `currentSession`. Lazily built
    /// on first `present` so it can capture `view` (`loadView` has run by
    /// then). Released when the VC deinits; `prepareForRemoval` /
    /// `present(nil)` tear the transcript down through it without dropping
    /// the coordinator itself.
    private var swapCoordinator: TranscriptSwapCoordinator?
    /// Top fade scrim. Pure AppKit (no `NSHostingView`, so it doesn't
    /// register a cursor rect that would shadow the transcript's I-beam).
    /// Its top band doubles as the title-bar drag/zoom region — see
    /// `TranscriptTopScrimView`.
    private var topScrim: TranscriptTopScrimView!
    /// The merged bottom cluster: fade + input bar + permission card in one
    /// SwiftUI tree, hosted by a single full-width, bottom-anchored,
    /// content-height `NSHostingView`. Replaces the four prior bottom
    /// siblings (bottom scrim + bar host + card host + cutout plumbing).
    ///
    /// `internal` (not `private`) is an access-modifier-only test seam: the
    /// `HostedComponentCenteringTests` CI gate samples this host's frame to
    /// assert the regime-B centering + width-cap contract, and
    /// `DetailPaneTranscriptHitTestTests` samples it to assert the host's
    /// geometry doesn't occlude the transcript above. No behavior change.
    /// The root view is a named `ChatBottomClusterRoot` wrapper (not
    /// `AnyView`) so the construction expression + environment chain are
    /// type-checked; the tests touch this only through `NSView` APIs
    /// (`.frame` / `.fittingSize`), so the concrete generic parameter
    /// doesn't affect them.
    var bottomClusterHost: NSHostingView<ChatBottomClusterRoot>!

    init(context: DetailContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // The detail router's `NSVisualEffectView` paints the vibrancy
        // backdrop behind the transcript scroll view (which sets
        // `drawsBackground = false`) — we just need a plain transparent
        // container view here.
        view = NSView()

        topScrim = TranscriptTopScrimView(bandHeight: Self.topFadeScrimHeight)
        topScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topScrim)

        // Single bottom-cluster host: fade + input bar + permission card in
        // one SwiftUI tree. It is FULL-WIDTH (the fade is full-width) and
        // BOTTOM-ANCHORED; its HEIGHT comes from the content
        // (`.intrinsicContentSize`), so it never publishes a full-pane
        // fitting size into the split (no window collapse — same regime-B
        // posture the old bar host had). There is NO top and NO height
        // constraint: the top edge floats at `view.bottom − cluster height`,
        // so the transcript above stays uncovered and keeps its clicks /
        // selection. A plain `NSHostingView` is non-occluding here purely by
        // geometry — no hit-test override, no click-through hack.
        bottomClusterHost = NSHostingView(rootView: makeBottomClusterRoot())
        bottomClusterHost.translatesAutoresizingMaskIntoConstraints = false
        bottomClusterHost.sizingOptions = [.intrinsicContentSize]
        view.addSubview(bottomClusterHost)

        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottomClusterHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomClusterHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomClusterHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No initial transcript attach here — the router owns that and
        // calls `present(sessionId:)` once this VC is mounted AND framed.
        // Self-attaching from `viewDidLoad` (before the fill constraints
        // sized the view) is exactly what forced the old deferred-attach
        // machinery; the router's "settle, then present" ordering removes
        // the need for it.
        //
        // No app-global observation installed here either: notification
        // activation and launch-failure alerts are owned by the stable
        // `DetailRouterViewController`, not self-observed per transcript VC
        // (that observation pinned this VC via a strong-`self`-across-await
        // re-arm and leaked it on every cross-kind round-trip).
    }

    // MARK: - Imperative presentation (driven by the router)

    /// Show `sessionId`'s transcript, or tear down to an empty chat
    /// backdrop when `nil` (the `.none` selection). The sole entry point
    /// the router calls — **synchronously**, after it has mounted and
    /// framed this VC, so the attach always runs against a settled
    /// frame. Replaces the old `model.selection`-observing path.
    ///
    /// `animated` carries the router's "fresh content" policy: a
    /// same-session-swap crossfade only runs on a first entry into the
    /// target session, never on warm re-entry. Defaults to `false` so the
    /// headless reentry merge gate (which drives `present` directly) stays
    /// on the synchronous path.
    func present(sessionId: String?, animated: Bool = false) {
        updateFocus(activeSessionId: sessionId)
        guard let sessionId else {
            swapCoordinator?.tearDownTranscript()
            return
        }
        transcriptSwapCoordinator().attachSession(sessionId, animated: animated)
    }

    /// `DetailRouterChild` — the router calls this right before it swaps
    /// this VC out on a cross-kind transition (`.transcript →
    /// .archive/.compose`). Tear the transcript down deterministically so
    /// the scroll view, sheet presenter, and `isRunning` task are released
    /// here rather than whenever ARC gets around to freeing the VC.
    func prepareForRemoval() {
        swapCoordinator?.tearDownTranscript()
    }

    /// Lazily build (and cache) the transcript-swap coordinator. Deferred to
    /// first `present` so it can capture `view` after `loadView` has run. The
    /// `insertScroll` seam keeps the sibling-z knowledge here — the scroll
    /// goes **below `topScrim`**, i.e. beneath both overlay siblings
    /// (`topScrim` / `bottomClusterHost`), so the bottom cluster's bar + card
    /// are never covered and the transcript's clicks aren't swallowed (M5).
    /// The `onFirstScreenReady` seam keeps the first-screen latency log here,
    /// fed the `(attachStart, sessionId)` the coordinator captured.
    private func transcriptSwapCoordinator() -> TranscriptSwapCoordinator {
        if let swapCoordinator { return swapCoordinator }
        let coordinator = TranscriptSwapCoordinator(
            container: view,
            context: context,
            insertScroll: { [weak self] scroll in
                guard let self else { return }
                self.view.addSubview(scroll, positioned: .below, relativeTo: self.topScrim)
            },
            onFirstScreenReady: { attachStart, sessionId in
                let ms = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
                appLog(
                    .info, "TranscriptDetailVC",
                    "[firstScreen] sidebar→first view=\(String(format: "%.1f", ms))ms "
                        + "session=\(sessionId.prefix(8))…")
            }
        )
        swapCoordinator = coordinator
        return coordinator
    }

    /// Keep `Session.setFocused` in sync with the shown session so
    /// unread state clears on entry. (Draft `sessionId` allocation for
    /// New Session lives in `ComposeSessionViewController`.)
    private func updateFocus(activeSessionId: String?) {
        if let active = activeSessionId, let session = context.sessionManager.session(active) {
            session.setFocused(true)
        }
        for sid in context.sessionManager.records.map(\.sessionId) where sid != activeSessionId {
            context.sessionManager.existingSession(sid)?.setFocused(false)
        }
    }

    // MARK: - SwiftUI overlay builders

    /// Build the bottom-cluster host root. The environment chain is
    /// encapsulated in the named `ChatBottomClusterRoot` wrapper (un-erased
    /// from an `AnyView(...)`), so the construction expression + modifier
    /// chain are type-checked at the call site. The closures stay owned by
    /// this VC with the same `[weak self]` semantics as before.
    private func makeBottomClusterRoot() -> ChatBottomClusterRoot {
        ChatBottomClusterRoot(
            context: context,
            onSubmit: { [weak self] submission, sessionId in
                guard let self else { return }
                submitSessionInput(
                    submission,
                    sessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    recentProjects: self.context.recentProjects,
                    model: self.context.model)
            },
            onBuiltinCommand: { [weak self] command, sessionId in
                guard let self else { return }
                runBuiltinSlashCommand(
                    command,
                    currentSessionId: sessionId,
                    sessionManager: self.context.sessionManager,
                    model: self.context.model)
            }
        )
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit
    /// executor-hop (`swift_task_deinitOnExecutorImpl`) that aborts in the
    /// XCTest process — the macOS 26 libswift_Concurrency `TaskLocal`
    /// teardown bug the rest of the codebase already guards against (see
    /// `SessionRuntime.swift`). The transcript's `isRunning` task is now
    /// owned (and cancelled in its own `nonisolated deinit`) by
    /// `TranscriptSwapCoordinator`; releasing `swapCoordinator` here cascades
    /// into that. This VC keeps no `Task` of its own, so the body is empty —
    /// the `nonisolated` attribute is what matters.
    nonisolated deinit {}
}

// MARK: - SwiftUI overlay subviews

/// Named root wrapper for `ChatSessionViewController.bottomClusterHost`.
/// Encapsulates the environment-injection chain that would otherwise be
/// erased behind an `AnyView(...)` at the host's construction site, so the
/// `bottomClusterHost` declaration carries a concrete generic parameter
/// (`NSHostingView<ChatBottomClusterRoot>`) and the root view's construction +
/// modifier chain are type-checked. The VC owns the callbacks; this struct
/// only threads them — and the `DetailContext` — into `ChatBottomCluster`.
///
/// Un-erasing does **not** by itself turn a missing `.environment(...)`
/// injection into a compile error — Observable-object / keyed-environment
/// values resolve at runtime. What it guards is the *construction
/// expression*: the wrapper's body has to name the injection explicitly (now
/// via `injectDetailEnvironment(_:)`), so the chain can't silently drift to
/// the wrong type.
struct ChatBottomClusterRoot: View {
    let context: DetailContext
    let onSubmit: (InputBarView2.Submission, String) -> Void
    let onBuiltinCommand: (BuiltinSlashCommand, String) -> Void

    var body: some View {
        ChatBottomCluster(
            model: context.model,
            onSubmit: onSubmit,
            onBuiltinCommand: onBuiltinCommand
        )
        .injectDetailEnvironment(context)
    }
}

/// The merged bottom cluster: fade gradient + input bar + permission card in
/// one SwiftUI tree, composited bottom-to-top in a single `ZStack`. The
/// always-mounted `bottomClusterHost` of `ChatSessionViewController` renders
/// this; it reads state from the shared `MainSelectionModel` so the AppKit VC
/// can drive selection flips imperatively from outside SwiftUI.
///
/// Three layers, back-to-front (all bottom-aligned):
///   1. **fade** — a decorative `FadeScrim` (`windowBackgroundColor` opaque at
///      the bottom edge, transparent at the top), full-width, bottom-aligned,
///      hit-testing disabled. It only paints; the opaque bar / card draw in
///      front of it in the same tree, so there is no scrim "hole" to cut.
///   2. **input bar** (`ChatRestingBar`) — centered, width-capped at
///      `composeMaxWidth` (512), bottom-padded by `chatBottomInset`.
///   3. **permission card** (conditional) — resolved from
///      `session.pendingPermissions.first`, width-capped at
///      `BlockStyle.maxLayoutWidth` (780), same `chatBottomInset` bottom
///      padding, so it bottom-aligns with the bar and grows *upward* without
///      moving the bar's `frame.minY`.
///
/// New Session's compose card is NOT here — it has its own
/// `ComposeSessionViewController` / `ComposeSessionView`. This cluster only
/// ever shows the bar + card for `.session(_)`, and `EmptyView` for every
/// other selection.
struct ChatBottomCluster: View {
    @Bindable var model: MainSelectionModel
    let onSubmit: (InputBarView2.Submission, String) -> Void
    /// Builtin slash command dispatcher, carrying the bar's live session
    /// id so `/new` / `/clear` can seed the new draft from it.
    let onBuiltinCommand: (BuiltinSlashCommand, String) -> Void

    @Environment(SessionManager.self) private var manager

    /// Routing decision for this cluster. Static + pure so the
    /// "which selection shows what input chrome" invariant is
    /// directly unit-testable — see `ChatComposeStackRoutingTests`.
    /// Only `.session(_)` renders the bar + card; everything else collapses
    /// to `.none`, which keeps the cluster from rendering on top of (and
    /// intercepting clicks on) pages where this VC might be mounted.
    /// `.newSession` is routed to `ComposeSessionViewController` by the
    /// router and never reaches this cluster, but it still maps to `.none`
    /// here as belt-and-suspenders.
    enum Content: Equatable {
        case none
        case chat(sessionId: String)
    }

    static func content(for selection: MainSelection, draftSessionId: String?) -> Content {
        switch selection {
        case .none, .newSession, .archive:
            return .none
        #if DEBUG
        case .demo:
            return .none
        #endif
        case .session(let sid):
            return .chat(sessionId: sid)
        }
    }

    var body: some View {
        let content = Self.content(for: model.selection, draftSessionId: model.draftSessionId)
        ZStack(alignment: .bottom) {
            switch content {
            case .none:
                EmptyView()
            case .chat(let sid):
                // The decorative fade. Full-width, bottom-aligned. Drawn
                // FIRST (behind) so the opaque bar / card composite on top of
                // it — no cutout needed. `.allowsHitTesting(false)` is only
                // for semantic correctness (the gradient shouldn't claim
                // clicks); the host absorbs the band's clicks anyway (the
                // accepted product trade-off — the bottom band isn't meant to
                // select transcript text).
                FadeScrim(.bottomToTop, height: ChatSessionViewController.bottomFadeScrimHeight)
                    .frame(maxWidth: .infinity, alignment: .bottom)

                // `.id(sid)` resets `InputBarView2`'s `@State` (text,
                // attachments, focus, completion) on every session switch.
                // Without it, the bar's local state persists across sessions
                // — the bar's `.task(id: draftKey)` restore is gated on
                // `text.isEmpty && attachments.isEmpty`, so a non-empty bar
                // would both display the previous session's body and overwrite
                // the new session's draft on the next keystroke.
                ChatRestingBar(
                    sessionId: sid,
                    draftKey: sid,
                    onSubmit: { submission in onSubmit(submission, sid) },
                    onBuiltinCommand: { command in onBuiltinCommand(command, sid) }
                )
                .id(sid)

                // The floating permission card, on top of the bar in the same
                // tree. Both are bottom-aligned with the same `chatBottomInset`
                // bottom padding, so the card grows UPWARD and the bar's
                // `frame.minY` never moves when a card appears (the PR#235→#281
                // "card pumps the bar" regression guard). `.id(sid)` rebuilds
                // the card subtree across session switches.
                permissionCard(for: sid)
                    .id(sid)
            }
        }
        // Full-width. Height is left to the content's own intrinsic size,
        // which the host reads via its `.intrinsicContentSize` sizing option.
        // The pill and card self-limit and center inside this width via their
        // own frames.
        .frame(maxWidth: .infinity)
    }

    /// The card subtree for one session. Resolves the session through the
    /// environment `SessionManager` (the same idempotent `prepareDraftSession`
    /// the bar uses) and reads `session.pendingPermissions.first` each render
    /// so the card stays in lockstep with the runtime without a shadow copy.
    /// Decision wiring is delegated to `PermissionCardOverlay.decisionHandlers`
    /// so the button→`session.respond` mapping lives in one unit-testable
    /// place (`PermissionCardWiringTests`).
    @ViewBuilder
    private func permissionCard(for sessionId: String) -> some View {
        let session = manager.prepareDraftSession(sessionId)
        ZStack(alignment: .bottom) {
            if let pending = session.pendingPermissions.first {
                let handlers = PermissionCardOverlay.decisionHandlers(
                    for: pending, session: session)
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce: handlers.onAllowOnce,
                    onAllowAlways: handlers.onAllowAlways,
                    onDeny: handlers.onDeny,
                    onAllowWithInput: handlers.onAllowWithInput
                )
                .frame(maxWidth: BlockStyle.maxLayoutWidth)
                .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
                .transition(
                    .scale(scale: 0.96, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        // Bottom edge flush with the resting bar's bottom (same inset), so the
        // card extends *up* from there. The card lives in the same cluster as
        // the bar but on a higher z-layer, so it overlaps the bar without
        // pumping the bar band's height.
        .frame(maxWidth: .infinity, alignment: .bottom)
        .padding(.bottom, ChatSessionViewController.chatBottomInset)
        .animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)
    }
}
