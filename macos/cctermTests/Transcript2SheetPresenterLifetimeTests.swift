import AppKit
import XCTest

@testable import ccterm

/// `Transcript2SheetPresenter` is rebuilt on every session attach
/// (`ChatSessionViewController.attachSession`). Its observation task used
/// to hold a strong `self` across the `withCheckedContinuation`
/// suspension, so the presenter↔task retain cycle leaked one presenter
/// per session switch — `stop()` cancels the task but never resumes the
/// suspended continuation, so the strong `self` lingered forever on a
/// detached session. These pin that it now deallocates.
@MainActor
final class Transcript2SheetPresenterLifetimeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPresenterDeallocatesAfterStop() {
        // `controller` + `host` outlive the presenter (owned by the test),
        // mirroring production where the Session owns the controller.
        let controller = Transcript2Controller()
        let host = NSView()

        weak var weakPresenter: Transcript2SheetPresenter?
        autoreleasepool {
            let presenter = Transcript2SheetPresenter(controller: controller, hostView: host)
            weakPresenter = presenter
            presenter.stop()
        }

        // Poll rather than asserting synchronously — task cancellation +
        // any autorelease can settle across a runloop turn (no sleep; the
        // predicate expectation spins the main runloop).
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in weakPresenter == nil }, object: nil)
        wait(for: [exp], timeout: 5)
        XCTAssertNil(weakPresenter, "presenter must deallocate after stop() — no retain cycle")
    }

    func testPresenterDeallocatesWithoutStopWhenReleased() {
        // Even without an explicit `stop()`, dropping the only strong
        // reference must free it (deinit cancels the task). The pure
        // no-cycle assertion.
        let controller = Transcript2Controller()
        let host = NSView()

        weak var weakPresenter: Transcript2SheetPresenter?
        autoreleasepool {
            weakPresenter = Transcript2SheetPresenter(controller: controller, hostView: host)
        }

        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in weakPresenter == nil }, object: nil)
        wait(for: [exp], timeout: 5)
        XCTAssertNil(weakPresenter, "presenter must deallocate when released — no retain cycle")
    }
}
