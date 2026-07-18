import AppKit
import ObjectiveC.runtime

/// Test-only harness that reproduces a live window resize faithfully enough
/// to probe transcript geometry **mid-drag** and **at end** — the two
/// phases the transcript treats differently (visible-only invalidation
/// during the drag; off-screen refill + anchor at the end).
///
/// A headless offscreen window never gets a window-server drag, so none of
/// the three production-observable effects of a real live resize happen on
/// their own. This driver supplies all three against the **real** production
/// handlers — nothing here is a stand-in for transcript logic, it only does
/// what the window server would:
///
///   1. `NSView.inLiveResize` reads `true` for the drag's duration — forced
///      via a scoped swizzle that ORs a per-view flag onto the real getter.
///      This is the exact state AppKit sets during a real drag, so the
///      coordinator's `inLiveResize` branch runs for real (not a re-created
///      copy of it).
///   2. Each drag frame posts `frameDidChangeNotification` — driven by a real
///      `setContentSize`, which the coordinator's observer picks up exactly
///      as it would live.
///   3. `viewWillStartLiveResize()` / `viewDidEndLiveResize()` fire — the
///      real AppKit methods, invoked directly (the latter drives the VC's
///      post-resize refill through the same `onLiveResizeEnded` closure a
///      real drag would).
///
/// Consistency guarantee: every geometry-affecting call the transcript makes
/// (visible-row `reloadData` + `noteHeightOfRows`, off-screen refill,
/// anchor scroll) is its own production code, reached through the same
/// entry points a real drag reaches. The only thing the harness fabricates
/// is the *trigger* (drag frames + `inLiveResize`), which is precisely what
/// the window server owns and a test cannot.
///
/// ## What it can and CANNOT observe (read before trusting a green)
///
/// It is faithful for **geometry / state**: which rows re-typeset, cached
/// widths, row heights, scroll anchor, expansion state. Assert on those.
///
/// It is **NOT** faithful for the **live-resize render path**. Faking
/// `inLiveResize` via a swizzle only changes what the *flag reports* — it
/// does not make AppKit take the real live-resize drawing path (content
/// preservation / redraw suppression), which the window server enters only
/// during a physical drag and no public API can trigger. So here a frame
/// change goes through the normal tile, which auto-dirties + redraws cells
/// like any resize — masking exactly the redraw *suppression* that produces
/// paint bugs. Concretely: the missing `TranscriptCellView.setFrameSize`
/// re-centering hook (content painted at the stale centre during a real
/// drag) could **not** be reproduced here — the harness "re-centred" fine
/// without the fix. That class of bug (correct intended geometry,
/// stale composited pixels) is invisible to any headless probe: reading
/// `layoutOrigin` returns the correct *intended* x regardless of paint, and
/// a `bitmapImageRepForCachingDisplay` capture force-redraws and heals the
/// staleness before you can measure it. Verify paint/re-centering by hand in
/// the running app (or a live-presentation display-link scaffold), never here.
@MainActor
struct LiveResizeHarness {
    let window: NSWindow
    /// The live-resized view — the transcript table documentView, whose
    /// `inLiveResize` the VC reads to pick its branch.
    let view: NSView

    /// Enter live resize: flag `inLiveResize` and fire the real will-start
    /// hook, matching AppKit's start-of-drag sequence.
    func begin() {
        InLiveResizeShim.install()
        InLiveResizeShim.setFaked(true, for: view)
        view.viewWillStartLiveResize()
    }

    /// One drag frame: resize the window's content to `width` and settle
    /// layout. `setContentSize` cascades to the clip → the outline's frame,
    /// posting the real `frameDidChangeNotification` — so the coordinator's
    /// per-frame, visible-only invalidation runs with `inLiveResize == true`.
    func step(toContentWidth width: CGFloat) {
        let height = window.contentRect(forFrameRect: window.frame).height
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    /// End the drag: drop `inLiveResize`, then fire the real
    /// `viewDidEndLiveResize` → the VC's post-resize refill (async off-main).
    /// Callers drain the runloop afterward to let the refill land.
    func end() {
        InLiveResizeShim.setFaked(false, for: view)
        view.viewDidEndLiveResize()
    }
}

/// Scoped swizzle of `NSView.inLiveResize` — ORs a per-view flag onto the
/// real value. Installed once per test process; a strict no-op for any view
/// not flagged, so it never perturbs real behavior (real drags, other
/// tests). Same test-infra technique as `ccterm_orderFrontForTesting`.
enum InLiveResizeShim {
    nonisolated(unsafe) private static var faked = Set<ObjectIdentifier>()
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard
            let original = class_getInstanceMethod(
                NSView.self, #selector(getter: NSView.inLiveResize)),
            let replacement = class_getInstanceMethod(
                NSView.self, #selector(NSView.ccterm_harness_inLiveResize))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    static func setFaked(_ on: Bool, for view: NSView) {
        if on {
            faked.insert(ObjectIdentifier(view))
        } else {
            faked.remove(ObjectIdentifier(view))
        }
    }

    static func isFaked(_ view: NSView) -> Bool { faked.contains(ObjectIdentifier(view)) }

    /// tearDown safety net: drop every flag so an early test failure (which
    /// skips `end()`) can't leak a stale `ObjectIdentifier` onto a later
    /// view that reuses the freed address.
    static func clearAll() { faked.removeAll() }
}

extension NSView {
    /// After the swizzle exchange this selector's IMP is the **original**
    /// `inLiveResize` getter, so the self-call reads the real value — which
    /// we OR with the harness flag.
    @objc fileprivate func ccterm_harness_inLiveResize() -> Bool {
        let real = ccterm_harness_inLiveResize()
        return real || InLiveResizeShim.isFaked(self)
    }
}
