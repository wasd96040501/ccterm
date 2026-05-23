import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Captures the **first observable** scroll origin / row geometry after
/// re-entering an already-populated session — the exact path #199
/// (commit 0d62875) tried to fix. The user reports the fix did not
/// actually land first-frame at tail; these tests measure it directly.
///
/// Three tests:
///
/// 1. `testProductionPathLandsAtTail` — drives the production factory +
///    attach sequence (`TranscriptScrollViewFactory.make` →
///    `addSubview` + constraints → `layoutSubtreeIfNeeded` →
///    `controller.scrollToTail()`). Asserts the clip view's
///    `bounds.origin.y` lands at the tail (visible content bottom) on
///    the very first observable frame — before any runloop drain.
///
/// 2. `testWithoutNoteNumberOfRowsStillLandsAtTail` — counter-factual:
///    same setup but with a parallel scroll-view builder that omits the
///    `noteNumberOfRowsChanged` call. Asserts the documented pre-fix
///    failure mode does NOT reproduce — origin still lands at tail —
///    showing that #199's added factory call is a no-op on this path.
///
/// 3. `testTickModelLayoutDoesForceRowTileOnFrameChange` — samples
///    `documentView.frame.height` at four transition points
///    (pre-mount → post-mount → post-`layoutSubtreeIfNeeded` →
///    post-drain). Falsifies the CLAUDE.md claim that
///    `layoutSubtreeIfNeeded` doesn't force NSTableView's row tile —
///    autolayout's table-frame change drives the tile inline via the
///    `heightOfRow` callback chain.
///
/// Filename ends in `SnapshotTests` so the runner opts it out of the
/// default suite (writes a PNG to `/tmp/ccterm-screenshots/` like other
/// snapshot tests). Run with:
///   `make test-unit FILTER=TranscriptScrollFirstFrameSnapshotTests`
@MainActor
final class TranscriptScrollFirstFrameSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture

    /// Picked to comfortably overflow the 800pt viewport once the
    /// transcript's content insets (top=44, bottom=180, visible≈576pt)
    /// are applied. 60 paragraphs × ~22pt/row ≈ 1320pt of content.
    private static let blockCount = 60
    private static let windowSize = CGSize(width: 720, height: 800)

    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    /// Mirrors the re-entry scenario: a `Transcript2Controller` whose
    /// `coordinator.blocks` is already populated (via the continuous
    /// bridge while no table was attached). `setHistory` with no table
    /// mounted lands the blocks directly into the coordinator's array.
    private func prepopulatedController() -> Transcript2Controller {
        let c = Transcript2Controller()
        c.setHistory(makeBlocks())
        XCTAssertEqual(c.blockIds.count, Self.blockCount, "fixture: setHistory should land all blocks")
        return c
    }

    // MARK: - Test 1: production path (does the fix actually work?)

    func testProductionPathLandsAtTail() throws {
        let controller = prepopulatedController()

        // Production: factory.make calls noteNumberOfRowsChanged so the
        // table's row tile runs inline against the pre-populated
        // dataSource.
        let scroll = TranscriptScrollViewFactory.make(controller: controller)

        let (window, measurements) = mountAndDriveAttach(controller: controller, scroll: scroll)
        defer { dismantleWindow(window) }

        attachReport("production-path", measurements: measurements)

        let m = measurements.afterScrollToTail
        XCTAssertEqual(
            m.numberOfRows, Self.blockCount,
            "table should report all rows after factory's note + layout (got \(m.numberOfRows))")
        XCTAssertGreaterThan(
            m.documentHeight, m.clipHeight,
            "content must overflow viewport for the test to be meaningful "
                + "(documentHeight=\(m.documentHeight) vs clipHeight=\(m.clipHeight))")

        let visibleBottomInClip = m.clipHeight - m.contentInsets.bottom
        let expectedTailOrigin = m.documentHeight - visibleBottomInClip
        let topClamp = -m.contentInsets.top

        let pinnedAtTop = abs(m.clipOriginY - topClamp) < 1
        XCTAssertFalse(
            pinnedAtTop,
            "FIRST FRAME PINNED AT TOP. "
                + "clip.bounds.origin.y=\(m.clipOriginY) ≈ -contentInsets.top=\(topClamp). "
                + "Expected ≈ \(expectedTailOrigin) (tail at visible bottom). "
                + "documentHeight=\(m.documentHeight), clipHeight=\(m.clipHeight), "
                + "rows=\(m.numberOfRows), lastRowRect=\(m.lastRowRect). "
                + "Conclusion: the #199 fix did NOT land first-frame at tail.")

        XCTAssertEqual(
            m.clipOriginY, expectedTailOrigin, accuracy: 2.0,
            "bounds.origin.y should land at tail within 2pt; "
                + "got \(m.clipOriginY), expected ≈ \(expectedTailOrigin)")

        capturePNG(scroll: scroll, name: "TranscriptScrollFirstFrame-Production")
    }

    // MARK: - Test 2: counter-factual — does removing the #199 row-tile
    //                 sync actually reproduce the bug it claims to fix?

    /// **Finding:** It does not. Even without `noteNumberOfRowsChanged`
    /// in the factory, source-phase `scrollToTail()` still lands the
    /// clip origin at the tail.
    ///
    /// Why: the host's `view.layoutSubtreeIfNeeded()` (in
    /// `TranscriptDetailViewController.attachSession`, predating #199)
    /// already drives the table from frame=.zero to its real frame, and
    /// that frame change triggers NSTableView's internal `tile()` through
    /// the `heightOfRow` callback chain — independent of whether
    /// `noteNumberOfRowsChanged` was called.
    ///
    /// Implication: the `noteNumberOfRowsChanged` call added by #199 is
    /// a no-op on this code path. If the user still observes a
    /// "top-then-snap" glitch in the running app, the cause is something
    /// other than what #199's commit message describes.
    func testWithoutNoteNumberOfRowsStillLandsAtTail() throws {
        let controller = prepopulatedController()

        let scroll = makeScrollViewWithoutRowTileSync(controller: controller)
        let (window, measurements) = mountAndDriveAttach(controller: controller, scroll: scroll)
        defer { dismantleWindow(window) }

        attachReport("no-note-counterfactual", measurements: measurements)

        let m = measurements.afterScrollToTail
        let topClamp = -m.contentInsets.top
        let visibleBottomInClip = m.clipHeight - m.contentInsets.bottom
        let expectedTailOrigin = m.documentHeight - visibleBottomInClip

        XCTAssertGreaterThan(
            m.documentHeight, 0,
            "documentView height should be sized by container.layoutSubtreeIfNeeded() "
                + "via the heightOfRow callback chain — even without an explicit "
                + "noteNumberOfRowsChanged. Got \(m.documentHeight).")

        XCTAssertGreaterThan(
            m.clipOriginY, topClamp + 1,
            "without the #199 row-tile sync, the documented failure mode predicts "
                + "origin pinned at top-clamp \(topClamp). Actual origin = \(m.clipOriginY) — "
                + "FAILURE MODE DID NOT REPRODUCE. The fix in #199 is a no-op.")

        XCTAssertEqual(
            m.clipOriginY, expectedTailOrigin, accuracy: 2.0,
            "without the explicit row-tile sync, origin should STILL land at the tail "
                + "(expected ≈ \(expectedTailOrigin), got \(m.clipOriginY))")

        capturePNG(scroll: scroll, name: "TranscriptScrollFirstFrame-NoNote")
    }

    // MARK: - Test 2.5: scroller knob position after scrollToTail
    //
    // Found in production via live `log stream` probe (May 2026): the
    // user reported a re-entry glitch where the transcript content
    // correctly lands at the tail but the **scrollbar thumb** flashes
    // at the top before fading out (overlay scrollers' brief
    // visibility on content change). Probes confirmed:
    //
    //   clip.bounds.origin.y = tail (correct)
    //   verticalScroller.doubleValue = 0 (WRONG — pre-scroll value)
    //
    // Root cause: `NSClipView.scroll(to:)` doesn't call
    // `reflectScrolledClipView(_:)` on its enclosing scroll view — the
    // documented contract — so the scroll view's scrollers stay
    // synced with the *previous* clip origin. The transcript's
    // `Transcript2Coordinator.scrollRowToBottom` (and `scrollRowToTop`)
    // call `scroll(to:)` directly without that follow-up. The bug
    // never surfaced in the offscreen scaffolds in this file because
    // none of them probed `verticalScroller.doubleValue`.
    //
    // This test fails on the buggy version (scroller.doubleValue ≈ 0
    // while clip origin is at tail) and is the regression gate for
    // whatever fix lands.

    /// Asserts that after `controller.scrollToTail()`, the vertical
    /// scroller's knob is at the tail (`doubleValue ≈ 1`), not stuck
    /// at the pre-scroll position. Uses the production attach path —
    /// the `Transcript2Coordinator.scrollRowToBottom` codepath — so
    /// any fix to that function will land first-class here.
    func testScrollerKnobLandsAtTailAfterScrollToTail() throws {
        let controller = prepopulatedController()
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        let (window, container) = makeOffscreenWindow(content: scroll)
        defer { dismantleWindow(window) }

        container.layoutSubtreeIfNeeded()
        controller.scrollToTail()

        let m = measure(scroll: scroll)
        let visibleBottomInClip = m.clipHeight - m.contentInsets.bottom
        let expectedTailOrigin = m.documentHeight - visibleBottomInClip

        guard let vScroller = scroll.verticalScroller else {
            XCTFail("scroll view has no verticalScroller")
            return
        }
        let knob = vScroller.doubleValue
        let knobProportion = vScroller.knobProportion

        attachString(
            """
            scroller-knob-after-scrollToTail
            ────────────────────────────────────────────────────────────
            clip.bounds.origin.y = \(m.clipOriginY)
            expected tail origin = \(expectedTailOrigin)
            documentHeight       = \(m.documentHeight)
            clipHeight           = \(m.clipHeight)

            verticalScroller
              doubleValue        = \(knob)     ← thumb position [0..1]
              knobProportion     = \(knobProportion)
              alphaValue         = \(vScroller.alphaValue)
              isHidden           = \(vScroller.isHidden)

            Reading the result:
              · clip origin at tail + knob ≈ 1.0  → scroller is consistent
              · clip origin at tail + knob ≈ 0    → BUG: NSClipView.scroll(to:)
                doesn't auto-call reflectScrolledClipView, so the scroller's
                thumb position is stuck at the value it had before the scroll.
                User-visible as "content at bottom but scrollbar at top".
            """, name: "scroller-knob")

        // Sanity: content origin should be at tail (matched by the
        // other tests in this file).
        XCTAssertEqual(
            m.clipOriginY, expectedTailOrigin, accuracy: 2.0,
            "fixture sanity: clip should be at tail")

        // The regression assertion: the scroller's knob should be at
        // the tail. With NSClipView.scroll(to:) called without
        // reflectScrolledClipView, the knob stays at 0.
        XCTAssertGreaterThan(
            knob, 0.9,
            "FIRST-FRAME SCROLLER THUMB STUCK AT TOP. "
                + "scroller.doubleValue=\(knob), expected ≈ 1.0 (tail). "
                + "Content (clip.bounds.origin.y) IS at tail "
                + "(\(m.clipOriginY) ≈ \(expectedTailOrigin)) but the "
                + "scroller thinks we're scrolled to the top. Caller of "
                + "NSClipView.scroll(to:) must follow up with "
                + "enclosingScrollView.reflectScrolledClipView(self).")
    }

    // MARK: - Test 3: CATransaction.flush() vs runloop drain — does the
    //                 source-phase scroll write reach the layer's
    //                 *presentation* tree on the same tick?

    /// PR #205 open-TODO probe (1/2). The offscreen tests above prove
    /// `clip.bounds.origin.y` (the **model** layer) lands at the tail on
    /// the very first observable source-phase tick. That tells us nothing
    /// about what the render server has actually composited — the user's
    /// "first paint at top, snap to tail" glitch could still be real if
    /// the CATransaction commit (which CoreAnimation runs at beforeWaiting)
    /// hasn't reached the presentation tree by the time the window paints
    /// its first frame.
    ///
    /// This test samples both `bounds.origin.y` (model) and
    /// `layer.presentation()?.bounds.origin.y` (presentation) at three
    /// points after `scrollToTail`:
    ///
    /// 1. **immediately after source-phase scroll** — model should be at
    ///    tail; presentation is whatever was last composited (likely `nil`
    ///    on a freshly attached layer that hasn't been rendered yet).
    /// 2. **after `CATransaction.flush()`** — forces the implicit commit
    ///    synchronously. If presentation now matches model, the commit is
    ///    sync after a flush — the only remaining asynchrony is the render
    ///    server, and the test scaffold can't observe that.
    /// 3. **after one runloop drain** — beforeWaiting flushes whatever the
    ///    explicit flush didn't catch.
    ///
    /// The XCTAttachment is the artefact; assertions are loose (model
    /// already known to be at tail by tests 1–2). Read the timeline to
    /// decide whether the next probe (CADisplayLink + presentation
    /// sampling on a live window — see
    /// `TranscriptScrollLivePresentationSnapshotTests`) is needed.
    func testCATransactionFlushPresentationTimeline() throws {
        let controller = prepopulatedController()
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        let (window, container) = makeOffscreenWindow(content: scroll)
        defer { dismantleWindow(window) }

        container.layoutSubtreeIfNeeded()
        let clip = scroll.contentView

        // Source phase: scrollToTail — same call as production attach.
        controller.scrollToTail()
        let afterScroll = sampleOrigins(clipView: clip)

        // Force the implicit CATransaction commit synchronously. If
        // CoreAnimation is sitting on a pending commit (the typical case
        // after a source-phase frame / bounds write), this drains it now
        // instead of waiting for beforeWaiting.
        CATransaction.flush()
        let afterFlush = sampleOrigins(clipView: clip)

        drainOnce()
        let afterDrain = sampleOrigins(clipView: clip)

        let m = measure(scroll: scroll)
        let visibleBottomInClip = m.clipHeight - m.contentInsets.bottom
        let expectedTailOrigin = m.documentHeight - visibleBottomInClip

        let report = """
            timing-probe: source-phase scroll → flush → drain
            ────────────────────────────────────────────────────────────
            expected tail origin = \(expectedTailOrigin)
            top-clamp            = \(-m.contentInsets.top)

            after source-phase scrollToTail (no flush, no drain)
              model.origin.y        = \(afterScroll.modelOrigin)
              presentation.origin.y = \(format(afterScroll.presentationOrigin))
              presentation present? = \(afterScroll.presentationOrigin != nil)

            after CATransaction.flush()
              model.origin.y        = \(afterFlush.modelOrigin)
              presentation.origin.y = \(format(afterFlush.presentationOrigin))
              presentation present? = \(afterFlush.presentationOrigin != nil)

            after one runloop drain
              model.origin.y        = \(afterDrain.modelOrigin)
              presentation.origin.y = \(format(afterDrain.presentationOrigin))
              presentation present? = \(afterDrain.presentationOrigin != nil)

            Reading the timeline:
              · model at tail in source-phase sample        → source-phase
                write reaches the model layer immediately.
              · presentation == nil in all three samples    → render server
                hasn't composited this layer at all (likely: offscreen
                window not promoted to a surface). Re-run with a live
                window via the display-link test for a real signal.
              · presentation at tail after flush            → CoreAnimation
                commits the write synchronously when flushed; only render
                server scheduling delays a frame.
              · presentation at top-clamp after flush AND
                drain                                       → commit IS
                landing the wrong value. The user-reported "top-then-snap"
                glitch is reproducible here and worth chasing.
            """
        attachString(report, name: "flush-presentation-timeline")

        // Model assertions only — the goal of this test is the timeline,
        // not a presentation-side gate (which depends on whether the
        // render server is willing to composite an alpha=0.01 window).
        XCTAssertEqual(
            afterScroll.modelOrigin, expectedTailOrigin, accuracy: 2.0,
            "source-phase model origin should land at tail (got \(afterScroll.modelOrigin))")
        XCTAssertEqual(
            afterFlush.modelOrigin, expectedTailOrigin, accuracy: 2.0,
            "model origin should still be at tail after flush (got \(afterFlush.modelOrigin))")
        XCTAssertEqual(
            afterDrain.modelOrigin, expectedTailOrigin, accuracy: 2.0,
            "model origin should still be at tail after drain (got \(afterDrain.modelOrigin))")
    }

    private struct OriginSample {
        let modelOrigin: CGFloat
        let presentationOrigin: CGFloat?
    }

    private func sampleOrigins(clipView: NSClipView) -> OriginSample {
        OriginSample(
            modelOrigin: clipView.bounds.origin.y,
            presentationOrigin: clipView.layer?.presentation()?.bounds.origin.y)
    }

    private func format(_ v: CGFloat?) -> String {
        guard let v else { return "nil" }
        return String(format: "%.3f", v)
    }

    // MARK: - Test 4: CLAUDE.md tick model verification

    /// **Finding:** the tick model in
    /// `NativeTranscript2/CLAUDE.md §1.2` (and the corollary in the root
    /// CLAUDE.md) is **misleading**. It claims:
    ///
    ///   > `view.layoutSubtreeIfNeeded()` runs autolayout NOW, but it
    ///   > does not force every AppKit subsystem. NSTableView's row
    ///   > layout, for example, is not an autolayout product —
    ///   > `layoutSubtreeIfNeeded` won't move it.
    ///
    /// What this test shows: when the container's
    /// `layoutSubtreeIfNeeded()` drives the table from `frame=.zero` to
    /// its real frame, the size change triggers NSTableView's internal
    /// `tile()` via the `heightOfRow` callback chain — synchronously,
    /// **before any beforeWaiting flush**. `documentView.frame.height`
    /// goes from `0` to its full tiled value inline.
    ///
    /// The CLAUDE.md claim is only correct for the narrow case of
    /// `tableView.layoutSubtreeIfNeeded()` called on a table whose frame
    /// hasn't changed. The first-attach path is precisely the opposite —
    /// the frame changes from zero, which IS what kicks off the tile.
    func testTickModelLayoutDoesForceRowTileOnFrameChange() throws {
        let controller = prepopulatedController()

        let scroll = makeScrollViewWithoutRowTileSync(controller: controller)
        let table = scroll.documentView as! NSTableView

        // Sample BEFORE the window mount: just the scroll view sitting
        // in memory with its dataSource bound. No subview attachment, no
        // window, no layout pass has driven the frame.
        let preMountHeight = table.frame.height
        let preMountRows = table.numberOfRows
        let preMountClipHeight = scroll.contentView.frame.height

        // Now mount into a container + offscreen window. The
        // window.contentView assignment + constraint activation may itself
        // trigger an immediate layout pass — sample again right after.
        let (window, container) = makeOffscreenWindow(content: scroll)
        defer { dismantleWindow(window) }

        let postMountHeight = table.frame.height
        let postMountRows = table.numberOfRows

        // Explicit autolayout — if postMount already tiled, this is a
        // no-op; if not, this is what does it.
        container.layoutSubtreeIfNeeded()
        let postLayoutHeight = table.frame.height
        let postLayoutRows = table.numberOfRows

        // Drain one runloop tick → beforeWaiting fires.
        drainOnce()
        let postDrainHeight = table.frame.height
        let postDrainRows = table.numberOfRows

        let report = """
            tick-model probe — when does NSTableView's row tile fire?
            ──────────────────────────────────────────────────────────
            pre-mount    tableHeight=\(preMountHeight)  numberOfRows=\(preMountRows)
                         clipHeight =\(preMountClipHeight)
                         (no window, no autolayout — scroll view sitting in memory)
            post-mount   tableHeight=\(postMountHeight)  numberOfRows=\(postMountRows)
                         (after window.contentView = container; before our
                         explicit layoutSubtreeIfNeeded — anything > 0 means
                         AppKit ran layout synchronously inside the mount)
            post-layout  tableHeight=\(postLayoutHeight)  numberOfRows=\(postLayoutRows)
                         (after container.layoutSubtreeIfNeeded())
            post-drain   tableHeight=\(postDrainHeight)   numberOfRows=\(postDrainRows)
                         (after one runloop drain — beforeWaiting flushed)
            tableFrame   \(table.frame)
            clipFrame    \(scroll.contentView.frame)
            """
        attachString(report, name: "tick-model")

        // Tick-model claim to test: source phase (layoutSubtreeIfNeeded)
        // does or does not trigger NSTableView's row tile?
        //
        // Reality (this test): the table is tiled BY THE TIME we observe
        // it after the mount/layout cascade — the row tile is triggered
        // when the table's frame changes from .zero, which is itself
        // driven by autolayout sizing the clip view. So
        // layoutSubtreeIfNeeded (transitively, via frame change) DOES
        // trigger the tile.
        XCTAssertGreaterThan(
            postLayoutHeight, 0,
            "CLAUDE.md tick-model claim is too strong: layoutSubtreeIfNeeded "
                + "DID drive NSTableView's tile() (documentHeight became "
                + "\(postLayoutHeight) before any runloop drain). The actual rule "
                + "is narrower — the tile is gated on FRAME changes, and autolayout "
                + "drives frame changes.")

        XCTAssertEqual(
            postLayoutRows, Self.blockCount,
            "post-layout numberOfRows should reflect coordinator.blocks "
                + "(got \(postLayoutRows))")
    }

    // MARK: - Mount / drive helpers

    private struct Measurement {
        let numberOfRows: Int
        let documentHeight: CGFloat
        let clipOriginY: CGFloat
        let clipHeight: CGFloat
        let contentInsets: NSEdgeInsets
        let lastRowRect: CGRect
    }

    private struct AttachMeasurements {
        let afterFactoryMake: Measurement
        let afterLayout: Measurement
        let afterScrollToTail: Measurement
        let afterOneDrain: Measurement
    }

    /// Drives the exact attach sequence used by
    /// `TranscriptDetailViewController.attachSession`, sampling state at
    /// each of the four observable points. Returns the window so the
    /// caller can keep it alive for an optional PNG capture; dismantle
    /// via `dismantleWindow(_:)` when done.
    private func mountAndDriveAttach(
        controller: Transcript2Controller,
        scroll: Transcript2ScrollView
    ) -> (NSWindow, AttachMeasurements) {
        let m0 = measure(scroll: scroll)
        let (window, container) = makeOffscreenWindow(content: scroll)

        // Mirror TranscriptDetailViewController.attachSession's
        // forced-layout pass — autolayout sizes the scroll view, clip
        // view, and table column to real width.
        container.layoutSubtreeIfNeeded()
        let m1 = measure(scroll: scroll)

        // Same source phase — scrollToTail is the very next call in
        // attachSession.
        controller.scrollToTail()
        let m2 = measure(scroll: scroll)

        drainOnce()
        let m3 = measure(scroll: scroll)
        let measurements = AttachMeasurements(
            afterFactoryMake: m0,
            afterLayout: m1,
            afterScrollToTail: m2,
            afterOneDrain: m3)
        return (window, measurements)
    }

    private func measure(scroll: NSScrollView) -> Measurement {
        let table = scroll.documentView as! NSTableView
        let lastRow = table.numberOfRows - 1
        let lastRect = lastRow >= 0 ? table.rect(ofRow: lastRow) : .zero
        return Measurement(
            numberOfRows: table.numberOfRows,
            documentHeight: table.frame.height,
            clipOriginY: scroll.contentView.bounds.origin.y,
            clipHeight: scroll.contentView.bounds.height,
            contentInsets: scroll.contentInsets,
            lastRowRect: lastRect)
    }

    private func attachReport(_ tag: String, measurements m: AttachMeasurements) {
        let report = """
            tag=\(tag)
            ────────────────────────────────────────────────────────────
            after factory.make
              numberOfRows = \(m.afterFactoryMake.numberOfRows)
              documentView.height = \(m.afterFactoryMake.documentHeight)
              clip.origin.y = \(m.afterFactoryMake.clipOriginY)
              clip.height = \(m.afterFactoryMake.clipHeight)
              lastRow = \(m.afterFactoryMake.lastRowRect)
            after layoutSubtreeIfNeeded
              numberOfRows = \(m.afterLayout.numberOfRows)
              documentView.height = \(m.afterLayout.documentHeight)
              clip.origin.y = \(m.afterLayout.clipOriginY)
              clip.height = \(m.afterLayout.clipHeight)
              lastRow = \(m.afterLayout.lastRowRect)
            after scrollToTail (source phase, no drain)
              numberOfRows = \(m.afterScrollToTail.numberOfRows)
              documentView.height = \(m.afterScrollToTail.documentHeight)
              clip.origin.y = \(m.afterScrollToTail.clipOriginY)
              clip.height = \(m.afterScrollToTail.clipHeight)
              lastRow = \(m.afterScrollToTail.lastRowRect)
              contentInsets = top=\(m.afterScrollToTail.contentInsets.top) bottom=\(m.afterScrollToTail.contentInsets.bottom)
              expected tail origin = \(m.afterScrollToTail.documentHeight - (m.afterScrollToTail.clipHeight - m.afterScrollToTail.contentInsets.bottom))
              top-clamp = -\(m.afterScrollToTail.contentInsets.top)
            after one runloop drain (beforeWaiting fired)
              numberOfRows = \(m.afterOneDrain.numberOfRows)
              documentView.height = \(m.afterOneDrain.documentHeight)
              clip.origin.y = \(m.afterOneDrain.clipOriginY)
              clip.height = \(m.afterOneDrain.clipHeight)
              lastRow = \(m.afterOneDrain.lastRowRect)
            """
        attachString(report, name: tag)
    }

    private func attachString(_ s: String, name: String) {
        let a = XCTAttachment(string: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func makeOffscreenWindow(content: NSView) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        return (window, container)
    }

    private func dismantleWindow(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func drainOnce() {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }

    private func capturePNG(scroll: NSScrollView, name: String) {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else {
            XCTFail("PNG capture: bitmapImageRepForCachingDisplay returned nil")
            return
        }
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        let img = NSImage(size: scroll.bounds.size)
        img.addRepresentation(rep)
        let url = ViewSnapshot.writePNG(img, name: name)
        let a = XCTAttachment(contentsOfFile: url)
        a.name = "\(name).png"
        a.lifetime = .keepAlways
        add(a)
    }

    /// Mirrors `TranscriptScrollViewFactory.make` but **omits the
    /// `noteNumberOfRowsChanged` call**. Used by tests 2 + 3 only, to
    /// exercise the documented pre-fix failure mode. Production callers
    /// always go through the real factory.
    private func makeScrollViewWithoutRowTileSync(
        controller: Transcript2Controller
    ) -> Transcript2ScrollView {
        let scroll = Transcript2ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .never
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView = Transcript2ClipView()
        scroll.contentInsets = TranscriptScrollViewFactory.contentInsets

        let table = Transcript2TableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        let coordinator = controller.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        coordinator.tableView = table
        table.coordinator = coordinator
        scroll.documentView = table
        // noteNumberOfRowsChanged intentionally omitted.
        return scroll
    }
}
