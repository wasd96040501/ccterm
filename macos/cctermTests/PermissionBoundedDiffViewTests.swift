import AppKit
import ObjectiveC.runtime
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `PermissionBoundedDiffView`
/// (migration plan §4.4-6, §4.4-7, §9). Drives the REAL embedded `DiffNSView`
/// (its `height(at:)` — `DiffView.swift:228`) and asserts the height clamp and
/// the owned highlight Task lifecycle. No re-implemented approximation.
@MainActor
final class PermissionBoundedDiffViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Mount the bounded-diff at a fixed width in an offscreen window so the
    /// embedded `DiffNSView` typesets at a real settled width.
    private func mounted(
        _ view: PermissionBoundedDiffView, width: CGFloat = 480
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    private func shortDiff() -> DiffBlock {
        DiffBlock(filePath: "command.sh", oldString: nil, newString: "echo hi")
    }

    private func tallDiff() -> DiffBlock {
        let body = (0..<60).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        return DiffBlock(filePath: "Tall.swift", oldString: nil, newString: body)
    }

    // MARK: - Short diff → intrinsic height (below cap)

    func testShortDiffSizesToDiffHeightBelowCap() {
        let view = PermissionBoundedDiffView(diff: shortDiff(), engine: nil)
        let window = mounted(view, width: 480)
        defer {
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()

        let contentWidth = view.diffView.bounds.width
        XCTAssertGreaterThan(contentWidth, 0, "The diff view settled to a real width.")
        let natural = view.diffView.height(at: contentWidth)
        XCTAssertGreaterThan(natural, 0, "A short diff has a positive natural height.")
        XCTAssertLessThan(natural, 240, "A one-line diff is below the 240pt cap.")
        XCTAssertEqual(
            view.resolvedHeight, natural, accuracy: 1.0,
            "Below the cap, the scroll height == DiffNSView.height(at: settledWidth).")

        // Independent monotonicity property (NOT a re-invocation of the same
        // measurement against itself): a diff with strictly MORE content lines
        // typesets strictly TALLER, and a 3-line diff lands above a 1-line diff
        // by at least ~2 line heights — so the below-cap height genuinely tracks
        // line count, catching a mis-measure that the min(X, cap)==min(X, cap)
        // form cannot.
        let threeLine = PermissionBoundedDiffView(
            diff: DiffBlock(filePath: "command.sh", oldString: nil, newString: "a\nb\nc"),
            engine: nil)
        let w2 = mounted(threeLine, width: 480)
        defer {
            w2.contentView = nil
            w2.close()
        }
        threeLine.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            threeLine.resolvedHeight, view.resolvedHeight,
            "A 3-line diff is taller than a 1-line diff (height tracks content).")
        XCTAssertLessThan(
            threeLine.resolvedHeight, 240,
            "Three lines are still below the 240pt cap.")
    }

    // MARK: - Tall diff → caps at 240

    func testTallDiffClampsToCap() {
        let view = PermissionBoundedDiffView(diff: tallDiff(), engine: nil)
        let window = mounted(view, width: 480)
        defer {
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()

        let contentWidth = view.diffView.bounds.width
        XCTAssertGreaterThan(
            view.diffView.height(at: contentWidth), 240,
            "60 lines typeset well past the cap (so the clamp is load-bearing).")
        XCTAssertEqual(
            view.resolvedHeight, 240, accuracy: 0.5,
            "An overflowing diff clamps to exactly the 240pt cap.")
    }

    // MARK: - Re-clamp on width change

    func testHeightReClampsOnWidthChange() {
        // A diff that fits at a wide width but wraps taller at a narrow width.
        let body = (0..<10).map {
            "let aVeryLongIdentifierNameNumber\($0) = computeSomethingExpensive(\($0))"
        }.joined(separator: "\n")
        let diff = DiffBlock(filePath: "Wrap.swift", oldString: nil, newString: body)
        let view = PermissionBoundedDiffView(diff: diff, engine: nil)
        let window = mounted(view, width: 700)
        defer {
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()
        let wideHeight = view.resolvedHeight
        let wideNatural = view.diffView.height(at: view.diffView.bounds.width)
        XCTAssertEqual(
            wideHeight, min(wideNatural, 240), accuracy: 1.0,
            "At the wide width the clamp is min(natural, cap).")

        // Shrink the window/container width and re-lay out.
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let narrowNatural = view.diffView.height(at: view.diffView.bounds.width)
        XCTAssertEqual(
            view.resolvedHeight, min(narrowNatural, 240), accuracy: 1.0,
            "After a width change the height re-clamps to the new min(natural, cap).")
    }

    // MARK: - cursor rects NOT suppressed on descendants (§4.4-2)

    func testDoesNotSuppressDescendantCursorRects() {
        // §4.4-2: only the full-pane PermissionCardHostView is cursor-rect-free.
        // This host MUST NOT override resetCursorRects (which would suppress its
        // descendants' rects, e.g. the embedded DiffNSView's pointing-hand over
        // the copy button). Verify behaviorally that the wrapper inherits
        // NSView's default resetCursorRects rather than declaring a suppressing
        // override — a future no-op override would change the resolved IMP.
        let baseIMP = class_getMethodImplementation(NSView.self, #selector(NSView.resetCursorRects))
        let wrapperIMP = class_getMethodImplementation(
            PermissionBoundedDiffView.self, #selector(NSView.resetCursorRects))
        XCTAssertEqual(
            wrapperIMP, baseIMP,
            "PermissionBoundedDiffView must NOT override resetCursorRects — it "
                + "inherits NSView's default so descendant cursor rects survive (§4.4-2).")

        // And the DiffNSView is embedded directly (its own rect path is reachable
        // through the wrapper, not behind an intermediary that re-hosts it).
        let view = PermissionBoundedDiffView(diff: shortDiff(), engine: nil)
        let window = mounted(view)
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertTrue(
            view.diffView.isDescendant(of: view),
            "The DiffNSView is embedded directly as a descendant of the wrapper.")
        // DiffNSView itself DOES override resetCursorRects (to add the
        // pointing-hand copy-button rect) — confirm that override is intact, so
        // the §4.4-2 chain (descendant keeps its own rect) is real, not vacuous.
        let diffIMP = class_getMethodImplementation(
            DiffNSView.self, #selector(NSView.resetCursorRects))
        XCTAssertNotEqual(
            diffIMP, baseIMP,
            "DiffNSView overrides resetCursorRects to register its own cursor rect "
                + "(DiffView.swift:365) — the rect the wrapper must not suppress.")
    }

    // MARK: - Owned highlight Task: writes back, then cancels on teardown

    func testHighlightTaskWritesBackThenCancelsOnTeardown() async {
        let engine = SyntaxHighlightEngine()
        await engine.load()
        let view = PermissionBoundedDiffView(
            diff: DiffBlock(
                filePath: "Hi.swift", oldString: nil,
                newString: "let x = 1\nlet y = 2\nfunc f() {}"),
            engine: engine)
        let window = mounted(view)
        defer {
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            view.isHighlightTaskRunning,
            "The view owns and starts a highlight Task on construct (§4.4-6).")
        XCTAssertFalse(
            view.highlightDidWriteBack,
            "The writeback has not run yet — only the un-highlighted diff laid out.")

        // Wait (no sleep) until the highlight Task's NON-cancelled writeback
        // actually ran. `highlightDidWriteBack` flips only after the await
        // returns and the diff is re-rendered with the resolved lineMap — it is
        // NOT satisfied by the synchronous un-highlighted layout in layout().
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { view.highlightDidWriteBack }
            },
            object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(
            view.highlightDidWriteBack,
            "The highlight writeback re-rendered the diff (§4.4-6 writeback path).")

        // Teardown cancels the Task — no stale writeback can land afterward.
        view.stop()
        XCTAssertFalse(
            view.isHighlightTaskRunning,
            "stop() cancels the highlight Task (§4.4-6 Task-lifetime guard).")
    }

    func testStopBeforeWritebackSuppressesIt() async {
        // Cancel the Task BEFORE it can write back, then prove the writeback is
        // never observed — the post-await `if Task.isCancelled { return }` guard
        // (DiffView.swift:66) keeps a stale highlight off a torn-down view.
        let engine = SyntaxHighlightEngine()
        let view = PermissionBoundedDiffView(
            diff: DiffBlock(
                filePath: "Hi.swift", oldString: nil,
                newString: "let x = 1\nlet y = 2"),
            engine: engine)
        let window = mounted(view)
        defer {
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()
        // Cancel synchronously, before the engine's batch returns.
        view.stop()
        XCTAssertFalse(view.isHighlightTaskRunning, "stop() cancels immediately.")
        // Give the (cancelled) Task a chance to resume past its await; assert it
        // did NOT write back. A drain of the main queue lets the cancelled
        // continuation run its `if Task.isCancelled { return }` guard.
        let drained = XCTestExpectation(description: "main-queue drain")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertFalse(
            view.highlightDidWriteBack,
            "A cancelled highlight Task must NOT write back to a torn-down view.")
    }

    func testRemoveFromSuperviewCancelsHighlightTask() async {
        let engine = SyntaxHighlightEngine()
        let view = PermissionBoundedDiffView(
            diff: DiffBlock(filePath: "Hi.swift", oldString: nil, newString: "let x = 1"),
            engine: engine)
        let window = mounted(view)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isHighlightTaskRunning, "Task is running while mounted.")
        view.removeFromSuperview()
        XCTAssertFalse(
            view.isHighlightTaskRunning,
            "removeFromSuperview cancels the highlight Task (card dismiss is "
                + "opacity-only, so cancellation ties to removal, not deinit).")
    }
}
