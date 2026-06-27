import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// §9.1 coverage for the animated transcript crossfade path that the two
/// single-width reentry merge gates (`TranscriptReentryLayoutCacheTests` /
/// `TranscriptHostReentryLayoutCacheTests`) deliberately do **not** exercise:
/// both drive `present(sessionId:)` with the default `animated: false`, so the
/// swap stays synchronous and never parks an outgoing scroll in
/// `TranscriptSwapCoordinator.fadingOutTranscript`.
///
/// ## What this gate locks
///
/// The load-bearing **finish-before-attach** ordering documented on
/// `attachSession`: a follow-up attach must flush a still-parked outgoing
/// crossfade scroll at its **head** (`finishTranscriptFadeOut()`), *before* the
/// incoming `bindData` re-registers the frameDidChange / liveScroll observers.
/// The hazard is specific to a **same-session re-entry** (A → B → A): the parked
/// outgoing scroll and the incoming scroll share one `Transcript2Coordinator`,
/// and `TranscriptScrollViewFactory.dismantle` calls a blanket
/// `removeObserver(coordinator)`. If the parked teardown were deferred past
/// `bindData`, that blanket removal would rip the freshly-registered observers
/// off the incoming scroll (same coordinator) — and a later width change would
/// no longer fire `tableFrameDidChange`, so the table would not re-tile on
/// resize.
///
/// ## How it's observed (no production seam)
///
/// Everything asserted here rides existing surfaces:
/// - parked-scroll teardown → the outgoing `NSScrollView.superview` drops to
///   `nil` (public `NSView`).
/// - incoming bind landed on the FRESH table → `session.controller.coordinator
///   .tableView` points at the new table, not the parked one (existing
///   coordinator property the hit-test gate already reads). This is the
///   offscreen-stable evidence that the rebind survived the parked scroll's
///   `dismantle`: `dismantle` only nils `tableView` when it still points at the
///   torn-down scroll, so a non-nil ref on the new table can only mean the bind
///   ran AFTER the blanket `removeObserver`, i.e. finish-before-attach held.
///
/// **Out of scope (manual-only).** The *firing* of the re-registered
/// frameDidChange observer on a live resize — and the absence of a white flash /
/// first-frame jitter / stale scrollbar across the fade — is not asserted: it
/// hangs on NSScrollView/NSClipView document-view sizing that does not settle
/// deterministically in an offscreen, alpha-0.01 window, so a resize-driven
/// assertion would be a fixture artifact rather than a contract check. Confirm
/// those by hand: A→B→A→A + draft→active promotion + mid-transcript resize, all
/// with no white flash, no first-frame jitter, no stale scrollbar.
///
/// The crossfade completion handler is async (CoreAnimation), so the test never
/// drains the runloop between the two animated attaches — `finishTranscriptFadeOut`
/// runs synchronously at the second attach's head regardless of whether the
/// completion fired, which is exactly the source-phase ordering under test.
@MainActor
final class TranscriptCrossfadeFinishBeforeAttachTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    private struct Fixture {
        let vc: ChatSessionViewController
        let manager: SessionManager
        let container: NSView
        let window: NSWindow
        let sessionIds: [String]
    }

    private func makeFixture(sessionCount: Int) -> Fixture {
        let repo = InMemorySessionRepository()
        var ids: [String] = []
        for i in 0..<sessionCount {
            let sid = UUID().uuidString
            ids.append(sid)
            repo.save(
                SessionRecord(
                    sessionId: sid, title: "S\(i)", cwd: "/tmp/s\(i)", status: .created))
        }
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })
        for sid in ids {
            manager.session(sid)?.controller.apply(.append(makeBlocks()))
        }

        let suite = "ccterm-crossfade-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let syntaxEngine = SyntaxHighlightEngine()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-crossfade-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        model.selection = .session(ids[0])

        let vc = ChatSessionViewController(
            context: DetailContext(
                model: model,
                sessionManager: manager,
                recentProjects: recentProjects,
                inputDraftStore: inputDraftStore,
                syntaxEngine: syntaxEngine))

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        addTeardownBlock {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: draftDir)
        }

        return Fixture(
            vc: vc, manager: manager, container: container,
            window: window, sessionIds: ids)
    }

    /// Walk the view tree for the scroll mounted under the chat VC whose
    /// document table belongs to `session`'s coordinator. There are at most
    /// two transcript scrolls live at once (the parked outgoing + the
    /// incoming); this finds the one currently bound to the coordinator.
    private func boundTable(for session: Session) -> Transcript2TableView? {
        session.controller.coordinator.tableView as? Transcript2TableView
    }

    /// A → B (animated, parks A) → A (animated, re-enters A and must flush
    /// the parked A at its head, before bindData re-registers A's observers).
    ///
    /// The window is live (`container.window != nil`) and there's an outgoing
    /// scroll on each switch, so `animateSwap` is true and the swap takes the
    /// crossfade path that parks the outgoing scroll. No runloop drain happens
    /// between the B→A pair, so A stays parked when the re-entry runs.
    func testReentryFlushesParkedSameSessionScrollBeforeRebind() async throws {
        let fx = makeFixture(sessionCount: 2)
        let sessionA = fx.manager.session(fx.sessionIds[0])!
        let sessionB = fx.manager.session(fx.sessionIds[1])!

        // Attach A synchronously (no outgoing yet → no crossfade).
        fx.vc.present(sessionId: fx.sessionIds[0])
        fx.container.layoutSubtreeIfNeeded()

        // Switch A → B animated. A is on a live window with an outgoing
        // scroll, so the swap crossfades and parks A's scroll.
        fx.vc.present(sessionId: fx.sessionIds[1], animated: true)

        // A's table is no longer the bound table (B's is), but A's scroll is
        // still mounted in the view tree — parked mid-fade, not yet dismantled.
        let bTable = boundTable(for: sessionB)
        XCTAssertNotNil(bTable, "B did not bind after the A→B crossfade attach")
        let parkedAScroll = fx.vc.view.subviews.compactMap { sub -> Transcript2ScrollView? in
            guard let scroll = sub as? Transcript2ScrollView,
                let table = scroll.documentView as? Transcript2TableView,
                table !== bTable
            else { return nil }
            return scroll
        }.first
        XCTAssertNotNil(
            parkedAScroll,
            "A→B animated swap did not park the outgoing A scroll in the view tree")
        XCTAssertNotNil(
            parkedAScroll?.superview,
            "parked A scroll should still be mounted mid-fade")

        // Re-enter A animated, WITHOUT draining the runloop — so A is still
        // parked. This attach's head must run `finishTranscriptFadeOut()`,
        // dismantling the parked A scroll (blanket `removeObserver(A.coordinator)`)
        // BEFORE its own `bindData` re-registers A.coordinator's observers on
        // the fresh A scroll.
        fx.vc.present(sessionId: fx.sessionIds[0], animated: true)
        fx.container.layoutSubtreeIfNeeded()

        // The parked A scroll must have been torn down at the re-entry head.
        XCTAssertNil(
            parkedAScroll?.superview,
            "re-entry did not flush the parked A scroll — finish-before-attach "
                + "ordering broken")

        // A is bound again, on a NEW table (not the parked one).
        let newATable = boundTable(for: sessionA)
        XCTAssertNotNil(newATable, "A did not re-bind after the re-entry attach")
        XCTAssertTrue(
            newATable !== (parkedAScroll?.documentView as? Transcript2TableView),
            "A re-bound to the parked table instead of the fresh one")

        // Observers re-registered on the fresh table: the re-entry's `bindData`
        // re-points `A.coordinator.tableView` at the new table and re-adds the
        // coordinator as the frameDidChange / liveScroll observer on it. The
        // weak `tableView` ref tracking the fresh table (asserted above) is the
        // deterministic, offscreen-stable evidence that the bind ran AFTER the
        // parked scroll's `dismantle` — `dismantle` only nils `tableView` when it
        // still points at the scroll being torn down (`=== scroll.documentView`),
        // so a fresh non-nil ref pointing at the NEW table proves the rebind was
        // not clobbered by the parked teardown's blanket `removeObserver`.
        //
        // The *firing* of that re-registered observer on a live resize (and the
        // absence of a white flash / stale scrollbar across the fade) is NOT
        // asserted here: it depends on NSScrollView/NSClipView document-view
        // sizing that does not settle deterministically in an offscreen,
        // alpha-0.01 window (the table's `bounds.width` clamps to
        // `maxLayoutWidth` regardless of the frame writes a headless test can
        // make), so any resize-driven assertion is a fixture artifact, not a
        // contract check. That dimension stays manual-only — see the type doc.
        XCTAssertTrue(
            sessionA.controller.coordinator.tableView === newATable,
            "re-entry left A.coordinator.tableView pointing somewhere other than "
                + "the freshly-bound table — the rebind did not survive the parked "
                + "scroll's teardown (finish-before-attach regression)")
    }
}
