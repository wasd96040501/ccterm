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
/// Around the transcript we mount full-bleed overlays, all attached for
/// the lifetime of the VC; their *contents* react to `model.selection`:
/// - top scrim — `TranscriptTopScrimView` (AppKit, hitTest passthrough)
/// - bottom scrim — `TranscriptBottomScrimView` (AppKit, hitTest
///   passthrough, even-odd cutouts at the attach button + pill)
/// - input bar — `NSHostingView<ChatComposeHostRoot>`. Its SwiftUI body
///   switches on `model.selection` via `ChatComposeStack.content(...)`:
///   `.session(_)` → chat resting bar, everything else → `EmptyView`.
///   `.newSession` / `.archive` / `.demo(_)` are routed away from this VC
///   entirely by `DetailRouterViewController` and never land here.
/// - permission card — `permissionCardHost` (`PassthroughHostingView`
///   hosting `PermissionCardOverlay`), a dedicated full-pane click-through
///   host **on top** of the bar. The card floats here instead of inside
///   the bar host so its footprint never pumps the bar host's height.
///
/// The bar host is bottom-anchored and takes only the bar's own intrinsic
/// height, so the transcript scroll view receives clicks in the scrim band
/// above it (and everywhere outside the permission card).
@MainActor
final class ChatSessionViewController: NSViewController, DetailRouterChild {
    /// Coordinate-space identifier for SwiftUI `GeometryReader`/
    /// `PreferenceKey` callbacks that report the attach button +
    /// pill rects. The canonical name for the detail pane's coordinate
    /// space, shared with `ComposeSessionViewController`'s compose card.
    static let detailCoordSpace = "ChatSessionViewController.detail"
    /// Top fade band height. Sized to match the unified toolbar so the
    /// gradient fades in exactly the strip the toolbar visually covers.
    private static let topFadeScrimHeight: CGFloat = 52
    /// Bottom fade band height. Sized to match the input bar's top
    /// edge, so the gradient stops where the bar begins. Derived from
    /// `chatBottomInset` (36) + `InputBarSessionChrome` row (~22) +
    /// `InputBarSessionChrome.barSpacing` (10) + `InputBarView2` pill
    /// (32) = 100. Hardcoded — those constants don't change at runtime.
    private static let bottomFadeScrimHeight: CGFloat = 100
    static let composeMaxWidth: CGFloat = 512
    static let chatBottomInset: CGFloat = 36
    static let detailHorizontalInset: CGFloat = 20
    static let detailVerticalInset: CGFloat = 20

    /// The detail-scope dependency bag, handed down from the router.
    /// `model` and the four injected services are read through this.
    let context: DetailContext

    /// Owns the transcript-swap state machine (build / bind / anchor /
    /// crossfade / tear-down + the per-attach turn-usage + `isRunning`
    /// sinks). The VC keeps "what the pane shows" (scrims, resting bar,
    /// permission-card host, focus, cutouts); the coordinator owns the
    /// transcript-attach mechanism and is the single owner of
    /// `currentSession`. Lazily built on first `present` so it can capture
    /// `view` (`loadView` has run by then). Released when the VC deinits;
    /// `prepareForRemoval` / `present(nil)` tear the transcript down through
    /// it without dropping the coordinator itself.
    private var swapCoordinator: TranscriptSwapCoordinator?
    /// Full-bleed overlays. All three are added to `view` once and
    /// stay mounted for the lifetime of the VC. The scrims are pure
    /// AppKit (no `NSHostingView` so they don't register cursor rects
    /// that would shadow the transcript's I-beam); the input bar /
    /// compose card stays SwiftUI-hosted via a plain `NSHostingView`.
    private var topScrim: TranscriptTopScrimView!
    private var bottomScrim: TranscriptBottomScrimView!
    // `internal` (not `private`) is an access-modifier-only test seam: the
    // `HostedComponentCenteringTests` CI gate samples this host's frame to
    // assert the regime-B centering + width-cap contract. No behavior change.
    // The root view is a named `ChatComposeHostRoot` wrapper (not `AnyView`)
    // so the construction expression + environment chain are type-checked;
    // the tests touch this only through `NSView` APIs (`.frame` /
    // `.fittingSize`), so the concrete generic parameter doesn't affect them.
    var restingBarHost: NSHostingView<ChatComposeHostRoot>!

    /// Full-pane floating host for the permission card (`PermissionCardOverlay`).
    /// A `PassthroughHostingView` (regime-A: `sizingOptions = []` + four-edge
    /// pin) layered **above** the transcript and `restingBarHost`. The card
    /// fades in place inside it; because this host's geometry is the full pane
    /// (not driven by the card), the bar host's intrinsic height stays a pure
    /// function of the bar content — the card never pumps the bar band. Clicks
    /// outside the card pass straight through to the transcript (see
    /// `PassthroughHostingView`).
    var permissionCardHost: PassthroughHostingView!

    /// Latest attach / pill rects reported by the chat resting bar
    /// in `detailCoordSpace`. Used to drive `bottomScrim`'s cutouts.
    /// Local to this VC — there's no cross-VC consumer that would
    /// need to read these.
    private var lastAttachRect: CGRect = .zero
    private var lastPillRect: CGRect = .zero

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

        bottomScrim = TranscriptBottomScrimView(bandHeight: Self.bottomFadeScrimHeight)
        bottomScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomScrim)

        restingBarHost = NSHostingView(rootView: makeComposeOrBarRoot())
        restingBarHost.translatesAutoresizingMaskIntoConstraints = false
        // A plain `NSHostingView` claims every point in its bounds for
        // hit-testing, shadowing the transcript table below it. We keep its
        // bounds to just the bar: the HEIGHT is left to the content's own
        // intrinsic size (`.intrinsicContentSize`), so the host is only as
        // tall as the bar — multi-line input grows it, nothing else (the
        // permission card no longer lives here; it floats in
        // `permissionCardHost`) — and the transcript receives clicks above.
        restingBarHost.sizingOptions = [.intrinsicContentSize]
        view.addSubview(restingBarHost)

        // WIDTH is owned by AppKit, HEIGHT by the content (above):
        // - centerX  → the bar is horizontally centered in the pane.
        // - width <= maxHostWidth (required) caps the host; the input pill
        //   (`composeMaxWidth`) self-centers inside via its own frame. The cap
        //   is the transcript column width (`BlockStyle.maxLayoutWidth`) plus
        //   horizontal padding — kept aligned with the column so the bar's
        //   centered axis matches the transcript's.
        // - width == maxHostWidth @high fills up to that cap on a wide pane,
        //   but yields to `leading >=` on a pane narrower than the cap (detail
        //   can be as small as 680) so the bar shrinks to fit the pane instead
        //   of overflowing its edges.
        let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset
        let restingBarHostWidthFill = restingBarHost.widthAnchor.constraint(
            equalToConstant: maxHostWidth)
        restingBarHostWidthFill.priority = .defaultHigh

        // Dedicated full-pane host for the permission card. Added AFTER
        // `restingBarHost` so it sits **on top** in z-order (the card
        // floats over the bar). `sizingOptions = []` is regime-A: the host
        // does NOT publish its content's `fittingSize`, so it can't leak a
        // size up into the window's constraint solver and collapse the window
        // — the four-edge pin below makes layout drive it from the pane
        // instead. `PassthroughHostingView` then makes everything outside the
        // card click-through so the transcript keeps its clicks + I-beam.
        permissionCardHost = PassthroughHostingView(
            rootView: AnyView(
                PermissionCardOverlay(model: context.model)
                    .injectDetailEnvironment(context)
            ))
        permissionCardHost.translatesAutoresizingMaskIntoConstraints = false
        permissionCardHost.sizingOptions = []
        view.addSubview(permissionCardHost)

        // Each scrim is sized to its visible band, anchored to its
        // edge. Cutout coordinates arrive in `restingBarHost`'s
        // SwiftUI coord space; `applyScrimCutouts` translates them
        // into the bottom scrim's local coord via `convert(_:from:)`.
        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.heightAnchor.constraint(equalToConstant: Self.topFadeScrimHeight),

            bottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomScrim.heightAnchor.constraint(equalToConstant: Self.bottomFadeScrimHeight),

            restingBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            restingBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            restingBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),
            restingBarHost.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor),
            restingBarHostWidthFill,

            permissionCardHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            permissionCardHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            permissionCardHost.topAnchor.constraint(equalTo: view.topAnchor),
            permissionCardHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    /// Push the latest reported rects into the bottom scrim. Called
    /// every time the chat resting bar fires a geometry callback —
    /// no Observation hop in between because the rects are local to
    /// this VC and there's no other consumer.
    private func applyScrimCutouts() {
        bottomScrim.attachRect = bottomScrim.convert(lastAttachRect, from: restingBarHost)
        bottomScrim.pillRect = bottomScrim.convert(lastPillRect, from: restingBarHost)
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
    /// goes **below `topScrim`**, i.e. beneath every overlay sibling
    /// (`bottomScrim` / `restingBarHost` / `permissionCardHost`), so the card
    /// is never covered and the transcript's clicks aren't swallowed (M5). The
    /// `onFirstScreenReady` seam keeps the first-screen latency log here, fed
    /// the `(attachStart, sessionId)` the coordinator captured.
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

    /// Build the chat resting-bar host root. The environment chain is
    /// encapsulated in the named `ChatComposeHostRoot` wrapper (un-erased
    /// from the former `AnyView(...)`), so the construction expression +
    /// modifier chain are type-checked at the call site. The closures stay
    /// owned by this VC with the same `[weak self]` semantics as before.
    private func makeComposeOrBarRoot() -> ChatComposeHostRoot {
        ChatComposeHostRoot(
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
            onAttachRect: { [weak self] rect in
                guard let self else { return }
                self.lastAttachRect = rect
                self.applyScrimCutouts()
            },
            onPillRect: { [weak self] rect in
                guard let self else { return }
                self.lastPillRect = rect
                self.applyScrimCutouts()
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

/// Named root wrapper for `ChatSessionViewController.restingBarHost`.
/// Encapsulates the environment-injection chain that used to be erased
/// behind an `AnyView(...)` at the host's construction site, so the
/// `restingBarHost` declaration carries a concrete generic parameter
/// (`NSHostingView<ChatComposeHostRoot>`) and the root view's construction +
/// modifier chain are type-checked. The VC owns the callbacks; this struct
/// only threads them — and the `DetailContext` — into `ChatComposeStack`.
///
/// Un-erasing does **not** by itself turn a missing `.environment(...)`
/// injection into a compile error — Observable-object / keyed-environment
/// values resolve at runtime. What it guards is the *construction
/// expression*: the wrapper's body has to name the injection explicitly (now
/// via `injectDetailEnvironment(_:)`), so the chain can't silently drift to
/// the wrong type.
struct ChatComposeHostRoot: View {
    let context: DetailContext
    let onSubmit: (InputBarView2.Submission, String) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void
    let onBuiltinCommand: (BuiltinSlashCommand, String) -> Void

    var body: some View {
        ChatComposeStack(
            model: context.model,
            onSubmit: onSubmit,
            onAttachRect: onAttachRect,
            onPillRect: onPillRect,
            onBuiltinCommand: onBuiltinCommand
        )
        .injectDetailEnvironment(context)
    }
}

/// Chat-mode resting input bar (or nothing). The always-mounted bar
/// host of `ChatSessionViewController` renders this; it reads state from
/// the shared `MainSelectionModel` so the AppKit VC can drive selection
/// flips imperatively from outside SwiftUI.
///
/// New Session's compose card is NOT here — it has its own
/// `ComposeSessionViewController` / `ComposeSessionView`. This stack only
/// ever shows the chat resting bar for `.session(_)`, and `EmptyView`
/// for every other selection.
struct ChatComposeStack: View {
    @Bindable var model: MainSelectionModel
    let onSubmit: (InputBarView2.Submission, String) -> Void
    let onAttachRect: (CGRect) -> Void
    let onPillRect: (CGRect) -> Void
    /// Builtin slash command dispatcher, carrying the bar's live session
    /// id so `/new` / `/clear` can seed the new draft from it.
    let onBuiltinCommand: (BuiltinSlashCommand, String) -> Void

    /// Routing decision for this overlay. Static + pure so the
    /// "which selection shows what input chrome" invariant is
    /// directly unit-testable — see `ChatComposeStackRoutingTests`.
    /// Only `.session(_)` renders a bar; everything else collapses to
    /// `.none`, which is what keeps the input bar from rendering on top
    /// of (and intercepting clicks on) pages where this VC might be
    /// mounted. `.newSession` is routed to `ComposeSessionViewController`
    /// by the router and never reaches this stack, but it still maps to
    /// `.none` here as belt-and-suspenders.
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
        ZStack {
            switch content {
            case .none:
                EmptyView()
            case .chat(let sid):
                // `.id(sid)` resets `InputBarView2`'s `@State`
                // (text, attachments, focus, completion) on every
                // session switch. Without it, the bar's local state
                // persists across sessions — the bar's `.task(id:
                // draftKey)` restore is gated on `text.isEmpty &&
                // attachments.isEmpty`, so a non-empty bar would
                // both display the previous session's body and
                // overwrite the new session's draft on the next
                // keystroke. Pre-#195 this reset came for free from
                // `.id(sid)` on `ChatHistoryView`, which used to
                // bracket the overlay-hosted input bar.
                ChatRestingBar(
                    sessionId: sid,
                    draftKey: sid,
                    onSubmit: { submission in onSubmit(submission, sid) },
                    onAttachRect: onAttachRect,
                    onPillRect: onPillRect,
                    onBuiltinCommand: { command in onBuiltinCommand(command, sid) }
                )
                .id(sid)
            }
        }
        // Fill the width the AppKit host hands us — the host is centered and
        // width-capped (at the widest content) by `ChatSessionViewController`.
        // Height is left to the content's own intrinsic size, which the host
        // reads via its `.intrinsicContentSize` sizing option. The pill and
        // permission card self-limit and center inside this width via their
        // own frames.
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: ChatSessionViewController.detailCoordSpace)
    }
}
