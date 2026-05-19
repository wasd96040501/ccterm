import AppKit
import SwiftUI

/// Host view that owns the sidebar-driven transcript swap. Replaces the
/// pre-bake `ChatHistoryView(sessionId: visibleSid).id(visibleSid)`
/// pattern in `RootView2` with a two-layer construction:
///
/// 1. **Live retainer (ZStack)** — every session that has ever entered
///    `.isLive` while the user was viewing it is kept mounted as a
///    `ChatHistoryView` inside the ZStack. Visibility is toggled via
///    `opacity` + `allowsHitTesting`, never via mount/unmount. So
///    switching between two live sessions is a z-order flip, not an
///    NSTableView reattach — no re-`reloadData()`, no scroll reset.
///
/// 2. **Ephemeral slot** — at most one ephemeral session lives in the
///    ZStack at a time, keyed on `.id(sid)`. Switching to an ephemeral
///    session forces a fresh `ChatHistoryView` mount (and the previous
///    ephemeral resident's `resetTranscript()` runs before we drop it).
///    Each ephemeral entry therefore goes through a true Phase 1/2
///    cold-load, matching the architectural invariant that re-entry
///    with stale coordinator blocks cannot occur.
///
/// On top of both layers, a **bake overlay** (`NSImage` of the outgoing
/// transcript captured at the moment the user clicked) covers any swap
/// transient until the incoming session's controller flips
/// `firstScreenReady`. The bake never animates — drop is binary, no
/// crossfade, per spec.
struct TranscriptSwapHost: View {
    /// Sidebar-derived intent. The host trails this with its own
    /// `visibleSessionId` state during a swap so the on-screen view
    /// only flips once the bake has been seated.
    let targetSessionId: String?

    @Environment(SessionManager.self) private var manager
    @Environment(TranscriptSearchBus.self) private var searchBus

    /// Sessions whose `ChatHistoryView` is currently mounted inside the
    /// retainer. A session enters when it becomes `isLive` AND the user
    /// has viewed it (so its view has been created). Sessions never
    /// auto-leave just because `isLive` flipped to false — eviction
    /// happens on the next swap in `pruneRetainerExceptVisible`, so the
    /// currently-visible session is never yanked mid-view.
    @State private var liveOrder: [String] = []
    @State private var liveSet: Set<String> = []

    /// Whatever session is presently on top. Lags `targetSessionId` by
    /// at most one frame: `performSwap` snapshots the outgoing view,
    /// promotes the incoming, then flips this. Bake covers the gap.
    @State private var visibleSessionId: String?

    /// Bake bitmap of the outgoing session's transcript taken at the
    /// moment the user clicked. Painted as a `NSImageView` overlay at
    /// the topmost z position so the user sees a frozen image of the
    /// old session until `firstScreenReady` fires on the new one.
    @State private var bakeImage: NSImage?

    /// Monotonic counter incremented at the start of every `performSwap`.
    /// The drop-bake task captures the counter when it begins; if a
    /// faster swap supersedes it, the captured value drifts and the
    /// task no-ops on its way out (no race against a later swap's
    /// freshly-installed bake).
    @State private var swapCounter: Int = 0

    /// Search query text bound to the toolbar's `.searchable` field.
    /// Hoisted from `ChatHistoryView` because the live retainer hosts
    /// multiple chat history views simultaneously and duplicate
    /// `.searchable` modifiers from sibling views race for the toolbar
    /// slot. With ownership here, the host routes the (single) query
    /// to whichever session is currently visible.
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            // Single rendering site for every visible session, live or
            // ephemeral, so a session that gets promoted from ephemeral
            // to live (e.g. draft → first send) doesn't migrate between
            // mount points — `ForEach(id: \.self)` preserves the view
            // (and its NSTableView) across the `liveSet` membership flip.
            // The currently-visible ephemeral session (if any) is
            // appended onto the end of `liveOrder`, so the rendering
            // order is stable: live sessions in their insertion order,
            // followed by the one transient ephemeral.
            ForEach(renderingOrder, id: \.self) { sid in
                ChatHistoryView(sessionId: sid)
                    .opacity(sid == visibleSessionId ? 1 : 0)
                    .allowsHitTesting(sid == visibleSessionId)
            }
            // Bake overlay — `allowsHitTesting(false)` lets the (now-
            // invisible) underlying view continue to receive layout
            // signals while we wait for `firstScreenReady`.
            if let bakeImage {
                BakeOverlay(image: bakeImage)
                    .allowsHitTesting(false)
            }
        }
        .searchable(
            text: $searchQuery,
            placement: .toolbar,
            prompt: Text("Find in transcript")
        )
        .searchFocused($isSearchFocused)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
        }
        .onSubmit(of: .search) {
            visibleSession?.controller.nextSearchHit()
        }
        // Shift+Return → previous match. Plain Return is consumed by
        // `.onSubmit(of: .search)`; we return `.ignored` for the plain
        // case so SwiftUI keeps propagating it.
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            visibleSession?.controller.previousSearchHit()
            return .handled
        }
        .onChange(of: searchQuery) { _, new in
            visibleSession?.controller.runSearch(new)
        }
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isSearchFocused = true
        }
        // Drop the search query when the user switches sessions so the
        // toolbar field doesn't carry the previous session's text
        // forward — matches the user expectation that ⌘F starts fresh
        // per chat.
        .onChange(of: visibleSessionId) { _, _ in
            searchQuery = ""
        }
        .onChange(of: targetSessionId, initial: true) { _, new in
            performSwap(to: new)
        }
        // Watch the visible session's `isLive` so a draft → first-send
        // promotion (where `targetSessionId` is unchanged but the
        // session has transitioned `notStarted` → `starting`) moves the
        // session into the live retainer without remounting its view.
        .onChange(of: visibleSessionIsLive) { _, isLive in
            guard isLive, let sid = visibleSessionId else { return }
            insertLive(sid)
        }
    }

    /// Currently-visible session, resolved from the manager (non-creating).
    /// Returns nil during the initial frame before `performSwap` has
    /// seated a visible target, or when the visible session has been
    /// evicted from the manager cache.
    private var visibleSession: Session? {
        visibleSessionId.flatMap { manager.existingSession($0) }
    }

    /// Computed: live retainer sessions in insertion order, plus the
    /// currently-visible ephemeral session (if any) appended at the
    /// end. Drives the single `ForEach` so SwiftUI keeps view identity
    /// stable across an ephemeral-to-live promotion.
    private var renderingOrder: [String] {
        if let sid = visibleSessionId, !liveSet.contains(sid) {
            return liveOrder + [sid]
        }
        return liveOrder
    }

    /// `@Observable`-backed read of the visible session's live flag —
    /// drives the live-flip `.onChange` above. Resolved through
    /// `existingSession` so a target that hasn't been cached yet
    /// (initial frame before `performSwap` has run) doesn't churn the
    /// session manager.
    private var visibleSessionIsLive: Bool {
        visibleSessionId
            .flatMap { manager.existingSession($0) }?
            .isLive ?? false
    }

    // MARK: - Lifecycle

    private func performSwap(to target: String?) {
        if visibleSessionId == target { return }
        swapCounter += 1
        let counter = swapCounter

        let outgoing = visibleSessionId
        let outgoingSession = outgoing.flatMap { manager.existingSession($0) }

        // 1. Snapshot the outgoing view (if any). Must run BEFORE the
        //    visibility flip, while the outgoing NSScrollView is still
        //    on-screen and drawn.
        if let view = outgoingSession?.controller.attachedRootView {
            bakeImage = Self.snapshot(of: view)
        } else {
            bakeImage = nil
        }

        // 2. Demote-from-retainer pass: any session in the retainer that
        //    has fallen to `!isLive` AND isn't the outgoing visible one
        //    (which we still want to keep mounted until bake drops) gets
        //    evicted now. Also evict the outgoing session if it became
        //    ephemeral while we weren't looking and we're about to leave
        //    it anyway.
        pruneRetainerExceptVisible(skip: outgoing)

        // 3. Promote-into-retainer:
        //    - **Outgoing** that is still live must be retained so its
        //      NSTableView doesn't unmount the moment we flip
        //      visibility. Without this, an ephemeral-rendered live
        //      session leaves the renderingOrder when no longer the
        //      visible ephemeral, the bridge keeps feeding events into
        //      a controller with no table, and the next entry pays a
        //      full re-attach + scroll-reset.
        //    - **Incoming** that is live joins the retainer so the
        //      view paints from the existing controller state (no
        //      cold-load Phase 1/2 needed — the bridge has already
        //      installed the blocks).
        if let outgoing, !liveSet.contains(outgoing),
            let session = outgoingSession, session.isLive
        {
            insertLive(outgoing)
        }
        if let target, let session = manager.existingSession(target), session.isLive {
            insertLive(target)
        }

        // 4. Outgoing teardown: if the outgoing session is ephemeral
        //    (not in retainer), reset its transcript so the next entry
        //    cold-loads. The actual `ChatHistoryView` unmounts when we
        //    flip `visibleSessionId` below — and SwiftUI's `.id` will
        //    re-key on the next ephemeral if applicable.
        if let outgoing, !liveSet.contains(outgoing),
            let session = manager.existingSession(outgoing)
        {
            session.resetTranscript()
        }

        // 5. Visibility flip. The retainer / ephemeral slot reshape on
        //    this state write; the bake sits on top hiding the change.
        visibleSessionId = target

        // 6. Replay messages-as-reset for ephemeral incoming sessions
        //    that already loaded history once (so `loadHistory` is a
        //    no-op but the bridge needs a fresh `.reset` to repopulate
        //    the (just-cleared) controller).
        if let target, !liveSet.contains(target),
            let session = manager.existingSession(target)
        {
            session.replayMessagesAsReset()
        }

        // 7. Drop bake once the incoming controller signals first-screen
        //    readiness (or after a bounded timeout — bake is a comfort
        //    layer, not a correctness gate).
        Task { @MainActor in
            await dropBakeWhenReady(target: target, counter: counter)
        }
    }

    /// Poll the target session's `firstScreenReady`; drop the bake the
    /// moment it flips true. Bounded by a 1500 ms ceiling so a stuck
    /// load can't pin the bake forever. The post-ready one-frame wait
    /// (`sleep(16ms)`) lets AppKit commit the new content before the
    /// bake disappears.
    private func dropBakeWhenReady(target: String?, counter: Int) async {
        // No target: drop immediately.
        guard let target else {
            if counter == swapCounter { bakeImage = nil }
            return
        }
        let session = manager.prepareDraftSession(target)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        while ContinuousClock.now < deadline {
            if counter != swapCounter { return }  // superseded
            if session.controller.firstScreenReady { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        if counter != swapCounter { return }
        // Let AppKit commit one frame of the incoming view at its final
        // layout/scroll position before we yank the bake. Without this
        // one tick, the bake can drop while the new view's first
        // display pass hasn't actually painted, exposing a blank frame.
        try? await Task.sleep(for: .milliseconds(16))
        if counter != swapCounter { return }
        bakeImage = nil
    }

    private func insertLive(_ sid: String) {
        if liveSet.contains(sid) { return }
        liveSet.insert(sid)
        liveOrder.append(sid)
    }

    private func removeLive(_ sid: String) {
        if !liveSet.contains(sid) { return }
        liveSet.remove(sid)
        liveOrder.removeAll { $0 == sid }
    }

    /// Walk `liveOrder`, evict any session whose `.isLive` is now false
    /// and is not the `skip` id. Used right before a visibility flip:
    /// the currently-visible session is preserved (we don't yank its
    /// view mid-frame) but otherwise demoted-to-ephemeral retainer
    /// slots are freed so the AppKit NSScrollView + NSTableView memory
    /// gets released.
    private func pruneRetainerExceptVisible(skip: String?) {
        let candidates = liveOrder
        for sid in candidates {
            if sid == skip { continue }
            guard let session = manager.existingSession(sid) else {
                removeLive(sid)
                continue
            }
            if !session.isLive {
                // Reset the controller before the SwiftUI unmount so the
                // bridge state and `firstScreenReady` go back to
                // first-entry posture — matches the ephemeral teardown
                // contract.
                session.resetTranscript()
                removeLive(sid)
            }
        }
    }

    // MARK: - Snapshot

    /// `cacheDisplay` the view's bounds into a backing-store-sized
    /// bitmap rep and wrap in `NSImage`. Returns nil on zero-bounded
    /// views or when AppKit refuses the rep — caller treats that as
    /// "no bake available", i.e. swap goes straight without dampening.
    private static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Topmost overlay during a swap — a layer-backed `NSImageView` painted
/// at native resolution. No SwiftUI `Image(nsImage:)` because the
/// SwiftUI image pipeline rescales / re-rasterizes through the GPU
/// blit path and can shift sub-pixel positions visibly; the
/// `NSImageView` route copies the rep verbatim.
private struct BakeOverlay: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleAxesIndependently
        iv.imageAlignment = .alignCenter
        iv.animates = false
        iv.wantsLayer = true
        iv.image = image
        return iv
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image !== image {
            nsView.image = image
        }
    }
}
