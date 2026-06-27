import AppKit
import Observation
import SwiftUI

/// Owns the transcript-swap state machine extracted verbatim from
/// `ChatSessionViewController`. The VC stays responsible for *what the pane
/// shows* (scrims, resting bar, permission-card host, focus, cutouts); this
/// coordinator owns the transcript-attach *mechanism* — building, binding,
/// anchoring, crossfading, and tearing down the `Transcript2ScrollView`, plus
/// the two per-attach sinks (turn-usage push + `isRunning` observation) that
/// drive `controller.setLoading` / `controller.setTurnUsage`.
///
/// ## Single owner of `currentSession`
///
/// This coordinator is the **sole** holder of `currentSession`. The idempotent
/// short-circuit, the outgoing-session capture, the assignment, and the clear
/// all live here, on the methods moved verbatim from the VC. The turn-usage
/// sink and the `isRunning` running-observation moved in alongside it because
/// both read `currentSession` (via `=== session` guards) and both are
/// per-attach assets re-created on every swap — keeping them out of the VC is
/// what lets `currentSession` have exactly one owner. Splitting them off would
/// force the VC and the coordinator to *both* hold `currentSession`, which is
/// the desync the crossfade machinery cannot tolerate (an in-flight fade reads
/// the parked outgoing session while the live one is bound).
///
/// ## Seam to the VC
///
/// Three closures + two refs cross the boundary, injected at `init`:
/// - `container` (the VC's `view`) — the host whose `bounds` / `window` /
///   `layoutSubtreeIfNeeded()` the attach reads, and the view the scroll's
///   four-edge constraints pin to.
/// - `context` — `sessionManager.prepareDraftSession` + `syntaxEngine`.
/// - `insertScroll` — adds the incoming scroll into the view tree at the
///   correct z-position (below `topScrim`, i.e. beneath every overlay sibling).
///   The VC owns the sibling-z knowledge (M5); the coordinator only knows
///   "insert it, then pin four edges".
/// - `onFirstScreenReady` — the VC's verbatim first-screen latency log,
///   handed the `(attachStart, sessionId)` pair so the coordinator doesn't
///   carry the logging concern.
@MainActor
final class TranscriptSwapCoordinator {
    /// The host view the transcript scroll is pinned into and whose geometry
    /// the attach reads. This is the VC's `view`.
    private unowned let container: NSView
    /// The detail-scope dependency bag — `sessionManager.prepareDraftSession`
    /// and `syntaxEngine` are read through it.
    private let context: DetailContext
    /// Adds the incoming scroll view into the view tree at the correct
    /// z-position (below the VC's `topScrim`, beneath every overlay sibling).
    /// Injected so the VC keeps the sibling-z knowledge; the coordinator
    /// pins the four edges itself after this runs.
    private let insertScroll: (NSView) -> Void
    /// Fires the VC's verbatim first-screen latency log when the cold-load
    /// edge lands, carrying `(attachStart, sessionId)`.
    private let onFirstScreenReady: (CFAbsoluteTime, String) -> Void

    /// The session currently driving the transcript, or nil for
    /// archive / demo branches. **Single owner** — see the type doc.
    private var currentSession: Session?
    /// AppKit-native transcript scroll view. Re-created when the
    /// selected session's controller changes; nil for archive /
    /// demo branches.
    private var transcriptScroll: Transcript2ScrollView?
    /// AppKit-native sheet presenter for the transcript controller's
    /// `pendingUserBubbleSheet` / `pendingImagePreview` request
    /// fields. Replaces the SwiftUI `.sheet(item:)` bindings the old
    /// `NativeTranscript2View` carried. Re-instantiated per session
    /// attach (same lifecycle as `transcriptScroll`); nil for
    /// archive / demo branches (those VCs own their own presenter).
    private var transcriptSheetPresenter: Transcript2SheetPresenter?

    /// Sink for `session.isRunning` → `controller.setLoading(_:)`.
    /// Re-armed on every session swap.
    private var runningObservationTask: Task<Void, Never>?

    /// The outgoing transcript scroll view mid-crossfade, kept mounted
    /// (behind the incoming one) until the fade-out completes, paired with
    /// the session whose controller it must be dismantled against. `nil`
    /// when no same-session-swap crossfade is in flight. A new attach
    /// flushes it synchronously first (`finishTranscriptFadeOut`) — see the
    /// load-bearing note in `attachSession`.
    private var fadingOutTranscript: (scroll: Transcript2ScrollView, session: Session)?

    /// Crossfade duration for a session→session transcript swap. Matches
    /// `DetailRouterViewController.childCrossfadeDuration` so a same-kind
    /// switch and a cross-kind switch feel identical. Only the fade is
    /// non-atomic: the build → settle → bind → `scrollToTail` attach runs
    /// synchronously in the click's source phase (the §2.19 single-width
    /// contract is untouched — alpha is composite-only), then the opacity
    /// animation rides CoreAnimation's clock from `beforeWaiting`.
    private static let transcriptCrossfadeDuration: CFTimeInterval = 0.18

    init(
        container: NSView,
        context: DetailContext,
        insertScroll: @escaping (NSView) -> Void,
        onFirstScreenReady: @escaping (CFAbsoluteTime, String) -> Void
    ) {
        self.container = container
        self.context = context
        self.insertScroll = insertScroll
        self.onFirstScreenReady = onFirstScreenReady
    }

    // MARK: - Transcript mount

    func attachSession(_ sessionId: String, animated: Bool = false) {
        // Contract: the router only calls `present` on a mounted, framed
        // VC, so the geometry-sensitive attach below (pin scroll view →
        // `layoutSubtreeIfNeeded` settles the table width → `scrollToTail`
        // anchors the clip) always has a real frame to work against.
        guard container.bounds.width > 0, container.bounds.height > 0 else {
            assertionFailure("attachSession called before the host view was framed")
            return
        }

        let session = context.sessionManager.prepareDraftSession(sessionId)
        if currentSession?.sessionId == sessionId, transcriptScroll != nil {
            return
        }

        // Flush a still-running transcript crossfade synchronously before
        // building the incoming scroll. **Load-bearing for A→B→A re-entry:**
        // `TranscriptScrollViewFactory.dismantle` calls a blanket
        // `removeObserver(coordinator)`, so if the outgoing scroll for the
        // SAME session is still parked when we re-enter it, deferring its
        // teardown would rip the frameDidChange / liveScroll observers off
        // the freshly-bound incoming scroll (same coordinator). Tearing the
        // parked scroll down here — before `bindData` below re-registers
        // them — keeps the incoming scroll's observers intact. A rapid
        // A→B→C collapses the same way: B snaps out as C builds.
        finishTranscriptFadeOut()

        // Stopwatch for "sidebar click → first rendered screen". Cold attaches
        // paint blank for the first tick (block building is off-main), so this
        // measures the gap the cold-load first-screen edge closes. Reported in
        // the `onFirstScreenReady` callback wired just before `loadHistory`.
        let attachStart = CFAbsoluteTimeGetCurrent()

        // Atomic structural swap: build, mount, bind, and anchor the
        // INCOMING transcript — all inside one disabled-animation
        // transaction — then either drop the OUTGOING one synchronously
        // (no window / cold start) or crossfade it out (the common
        // session→session switch). Building the new scroll on top of the
        // old and never removing the old before the new is live means the
        // user never sees an empty pane.
        let outgoingScroll = transcriptScroll
        let outgoingSession = currentSession
        // Crossfade only when the router asked for it (a first entry into
        // this session — never a warm re-entry), there's an outgoing
        // transcript, AND we're on a live window. Without a window (the
        // §2.19 reentry merge gate, any headless attach) the swap stays
        // synchronous — identical to the pre-animation behavior, so the
        // probe sees the same writes.
        let animateSwap = animated && outgoingScroll != nil && container.window != nil

        // Explicit begin/commit (not `defer`): the crossfade below must run
        // OUTSIDE this disabled-animation transaction, or the opacity
        // animation would be suppressed by `setDisableActions(true)`. There
        // are no early returns between here and the commit.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scroll = TranscriptScrollViewFactory.make(controller: session.controller)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Start the incoming scroll transparent when we're going to fade it
        // in. Set inside the disabled transaction so the 0 itself doesn't
        // animate; the fade up to 1 is a separate group after commit.
        if animateSwap {
            scroll.wantsLayer = true
            scroll.alphaValue = 0
        }
        // Insert just below the top scrim — i.e. in front of the still-mounted
        // outgoing scroll view — so the incoming transcript covers it (or,
        // when animating, crossfades over it).
        insertScroll(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Pull layout into the current call stack so the table reaches
        // its real width before we bind the dataSource — with the bind
        // deferred until now, AppKit has no rows to query and the
        // autolayout pass settles without any `heightOfRow` queries at
        // transient widths. The downstream `scrollToTail` and history
        // load can then run in the same source phase.
        container.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: session.controller)
        transcriptScroll = scroll
        currentSession = session

        // Re-attach scroll: bridge-accumulated blocks from a previous
        // mount land here with no setHistory follow-up (loadHistory is
        // idempotent and short-circuits). Anchor to the tail synchronously
        // now that the table has real width.
        //
        // Resident reentry telemetry: the first tile `scrollToTail` forces
        // queries `heightOfRow` for every row, and cache *misses* (blocks the
        // bridge appended while this session was detached, or a width change
        // since it was last displayed) recompute their `RowLayout` on the main
        // thread right here. We read the coordinator's monotonic compute
        // counter as a delta around this one tile so the cost is logged ONCE
        // per attach (session switches are user-paced — not a hot path); the
        // per-row typeset itself is never logged.
        let layoutComputesBeforeTile = session.controller.mainThreadLayoutComputes
        let reentryTileStart = CFAbsoluteTimeGetCurrent()
        session.controller.scrollToTail()
        let reentryTileMs = (CFAbsoluteTimeGetCurrent() - reentryTileStart) * 1000
        let reentryTypeset =
            session.controller.mainThreadLayoutComputes &- layoutComputesBeforeTile

        // Attach syntax engine (idempotent).
        session.controller.attachSyntaxEngine(context.syntaxEngine)

        // Sheet presenter is per-attach: it captures `view` (for
        // `window`) and the session's controller. The presenter
        // observes `pendingUserBubbleSheet` / `pendingImagePreview`
        // and presents AppKit-native sheets via
        // `view.window?.beginSheet`. Replaces the SwiftUI
        // `.sheet(item:)` bindings the old `NativeTranscript2View`
        // carried. Stop the outgoing one first.
        transcriptSheetPresenter?.stop()
        transcriptSheetPresenter = Transcript2SheetPresenter(
            controller: session.controller, hostView: container)

        // Kick history load + initial running pill sync (mirrors
        // `ChatHistoryView.task(id: sessionId)`).
        appLog(
            .info, "TranscriptDetailVC",
            "[history] attach session=\(sessionId.prefix(8))… "
                + "loadState=\(String(describing: session.historyLoadState)) "
                + "msgCount=\(session.messages.count) "
                + "blockCount=\(session.controller.blockCount) "
                + "reentryTypeset=\(reentryTypeset) "
                + "reentryTile=\(String(format: "%.1f", reentryTileMs))ms")
        // Log the cold-load first-screen latency once it lands. Capture only
        // the sessionId string + start time (no `self` / `session`) so the
        // closure stored on the controller can't form a retain cycle. On a warm
        // re-entry the edge already fired during the original cold load, so the
        // latched callback never re-fires — no spurious log.
        session.controller.onFirstScreenReady = { [onFirstScreenReady] in
            onFirstScreenReady(attachStart, sessionId)
        }
        session.loadHistory()
        session.controller.setLoading(session.isRunning)
        // turnUsage rides the imperative channel: push the current value once on
        // mount, then let `onTurnUsageChange` drive live updates (the runtime
        // fires it synchronously at each write — no observation pull). The turn
        // clock's start anchor rides the same site: it only changes at a turn
        // boundary (which always coincides with a usage write), so re-reading
        // `session.turnStartedAt` here keeps the pill's elapsed clock in sync
        // without a second sink.
        session.controller.setTurnUsage(session.turnUsage)
        session.controller.setTurnStartedAt(session.turnStartedAt)
        session.onTurnUsageChange = { [weak self, weak session] usage in
            guard let self, let session, self.currentSession === session else { return }
            session.controller.setTurnUsage(usage)
            session.controller.setTurnStartedAt(session.turnStartedAt)
        }

        // Re-arm the `isRunning` → controller sink (cancels the old).
        startRunningObservation(for: session)

        // Synchronous path: drop the outgoing transcript last, now that the
        // incoming one is live and on top — no blank frame in between. Stays
        // inside the disabled-animation transaction so the teardown doesn't
        // flicker. The animated path leaves the outgoing scroll mounted and
        // hands it to the crossfade below.
        if !animateSwap, let outgoingScroll, let outgoingSession {
            TranscriptScrollViewFactory.dismantle(
                outgoingScroll, controller: outgoingSession.controller)
            outgoingScroll.removeFromSuperview()
        }

        CATransaction.commit()
        NSAnimationContext.endGrouping()

        // Cosmetic crossfade, OUTSIDE the disabled transaction so it can
        // actually animate. The incoming content is already live (typeset,
        // bound, scrolled to tail above), so the first composited fade frame
        // shows real content over the outgoing transcript.
        if animateSwap, let outgoingScroll, let outgoingSession {
            crossfadeTranscriptSwap(
                incoming: scroll, outgoing: outgoingScroll, outgoingSession: outgoingSession)
        }
    }

    /// Fade the incoming transcript in and the outgoing one out together,
    /// then dismantle the outgoing scroll on completion. Parks the outgoing
    /// scroll in `fadingOutTranscript` so a follow-up attach can flush it
    /// synchronously (see `attachSession`'s load-bearing note on the
    /// blanket `removeObserver`).
    private func crossfadeTranscriptSwap(
        incoming: Transcript2ScrollView,
        outgoing: Transcript2ScrollView,
        outgoingSession: Session
    ) {
        outgoing.wantsLayer = true
        fadingOutTranscript = (outgoing, outgoingSession)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.transcriptCrossfadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.finishTranscriptFadeOut(expected: outgoing)
        }
    }

    /// Tear down the parked outgoing transcript scroll. Idempotent and
    /// called from three places: the crossfade completion (with `expected`
    /// set), synchronously at the head of a new attach to flush an in-flight
    /// fade, and from `tearDownTranscript`. The `expected` guard makes a
    /// late completion for an already-flushed scroll a no-op.
    private func finishTranscriptFadeOut(expected: Transcript2ScrollView? = nil) {
        guard let parked = fadingOutTranscript else { return }
        if let expected, expected !== parked.scroll { return }
        fadingOutTranscript = nil
        TranscriptScrollViewFactory.dismantle(
            parked.scroll, controller: parked.session.controller)
        parked.scroll.removeFromSuperview()
    }

    func tearDownTranscript() {
        // Drop a parked outgoing scroll first — otherwise tearing down only
        // the current scroll would leave a mid-fade ghost mounted when the
        // router swaps this VC out cross-kind during a session→session fade.
        finishTranscriptFadeOut()
        if let scroll = transcriptScroll, let session = currentSession {
            TranscriptScrollViewFactory.dismantle(scroll, controller: session.controller)
            scroll.removeFromSuperview()
        }
        transcriptScroll = nil
        currentSession = nil
        transcriptSheetPresenter?.stop()
        transcriptSheetPresenter = nil
        runningObservationTask?.cancel()
        runningObservationTask = nil
    }

    private func startRunningObservation(for session: Session) {
        runningObservationTask?.cancel()
        runningObservationTask = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                guard let session else { return }
                await withCheckedContinuation { cont in
                    withObservationTracking {
                        _ = session.isRunning
                    } onChange: {
                        Task { @MainActor in cont.resume() }
                    }
                }
                guard let self, self.currentSession === session else { return }
                session.controller.setLoading(session.isRunning)
            }
        }
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit
    /// executor-hop (`swift_task_deinitOnExecutorImpl`) that aborts in the
    /// XCTest process — the macOS 26 libswift_Concurrency `TaskLocal`
    /// teardown bug the rest of the codebase already guards against (see
    /// `SessionRuntime.swift`). Cancelling a `Task` needs no isolation.
    nonisolated deinit {
        runningObservationTask?.cancel()
    }
}
