import XCTest

@testable import ccterm

/// `MainSelectionModel.promote(to:)` — the in-place re-route used when a
/// draft's first message flips its phase `.draft → .active` without
/// changing the selection value. Plain `select(_:)` no-ops on an unchanged
/// value; `promote` must still notify the structural observer so the
/// router swaps the draft-landing VC for the transcript.
@MainActor
final class MainSelectionModelPromoteTests: XCTestCase {

    private final class SpyObserver: MainSelectionObserver {
        var calls: [MainSelection] = []
        func selectionDidChange(to selection: MainSelection) { calls.append(selection) }
    }

    func test_promote_firesObserver_whenSelectionUnchanged() {
        let model = MainSelectionModel()
        let spy = SpyObserver()
        model.selectionObserver = spy
        model.select(.session("a"))
        spy.calls.removeAll()

        // Same selection value — `select` would no-op, but `promote` must
        // re-fire so the router re-reads the (now active) phase.
        model.promote(to: "a")
        XCTAssertEqual(spy.calls, [.session("a")])
    }

    func test_select_noops_whenSelectionUnchanged() {
        // Baseline: `select` really does no-op (the reason `promote` exists).
        let model = MainSelectionModel()
        let spy = SpyObserver()
        model.selectionObserver = spy
        model.select(.session("a"))
        spy.calls.removeAll()
        model.select(.session("a"))
        XCTAssertTrue(spy.calls.isEmpty)
    }

    func test_promote_selectsTarget_whenSelectionDiffers() {
        let model = MainSelectionModel()
        let spy = SpyObserver()
        model.selectionObserver = spy
        model.select(.session("a"))
        spy.calls.removeAll()

        // Different target → falls back to a normal cross-kind select.
        model.promote(to: "b")
        XCTAssertEqual(model.selection, .session("b"))
        XCTAssertEqual(spy.calls, [.session("b")])
    }
}
