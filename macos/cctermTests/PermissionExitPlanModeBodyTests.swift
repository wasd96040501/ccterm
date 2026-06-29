import AgentSDK
import AppKit
import Foundation
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.exitPlanMode`
/// permission-card body (migration plan §4.4, §9). Drives the REAL body builder
/// (`PermissionExitPlanModeCardBodyBuilder.makeBody`), mounts the produced
/// `NSView`, and asserts the parsed headline + the v1/V2 plan branch actually
/// render into the production subviews — no re-implemented approximation, no
/// test-only seam.
///
/// The `.exitPlanMode` builder is registered against the dispatch's STUB until
/// the (single) integration step repoints `permissionCardBodyBuilder(for:)` at
/// `PermissionExitPlanModeCardBodyBuilder`. This class therefore drives
/// the real content builder directly (the production conformer this file owns)
/// AND pins `PermissionCardKind.kind(for:)` resolution so the `.exitPlanMode`
/// wiring this builder will serve is itself asserted.
///
/// Distinct from `PermissionExitPlanModeCardBodyTests` (which exercises the
/// surviving SwiftUI `PermissionExitPlanModeCardBody` struct's data getters this
/// phase): this class drives the AppKit replacement through
/// `PermissionCardBodyBuilding` and asserts the rendered layout.
@MainActor
final class PermissionExitPlanModeBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func request(toolName: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "exit-\(UUID().uuidString)", toolName: toolName, input: input)
    }

    /// Build the body the production way — through the real
    /// `PermissionCardBodyBuilding` conformer this file owns — and downcast to the
    /// concrete view so the test can read the rendered subviews. The downcast is
    /// itself an assertion: the builder must hand back this body type.
    private func makeMountedBody(
        toolName: String, input: [String: Any], width: CGFloat = 460
    ) -> (PermissionExitPlanModeCardBodyView, NSWindow) {
        let req = request(toolName: toolName, input: input)
        // Pin the kind resolution the dispatch keys off so the `.exitPlanMode`
        // routing this builder serves is asserted, not just the view shape.
        XCTAssertEqual(
            PermissionCardKind.kind(for: req), .exitPlanMode,
            "An \(toolName) request must resolve to the .exitPlanMode kind so the dispatch routes here.")
        let builder = PermissionExitPlanModeCardBodyBuilder()
        let view = builder.makeBody(request: req, engine: nil)
        guard let body = view as? PermissionExitPlanModeCardBodyView else {
            XCTFail("The .exitPlanMode builder must build a PermissionExitPlanModeCardBodyView.")
            return (PermissionExitPlanModeCardBodyView(request: req), NSWindow())
        }

        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        body.layoutSubtreeIfNeeded()
        return (body, window)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    // MARK: - Headline (always rendered, localized)

    func testHeadlineRendersLocalizedString() {
        let (body, window) = makeMountedBody(
            toolName: "ExitPlanMode", input: ["plan": "1. Refactor\n2. Test"])
        defer { close(window) }
        XCTAssertEqual(
            body.renderedHeadline,
            String(localized: "Review the plan to leave plan mode?"),
            "The headline shows the localized review prompt (parity with PermissionExitPlanModeCardBody.headline).")
    }

    // MARK: - v1 with plan → monospace scroll block

    func testV1PlanRendersIntoMonospaceScrollBlock() {
        let plan = """
            ## Refactor permission cards

            1. Extract per-kind body views into their own files.
            2. Wire the dispatch into the card.
            """
        let (body, window) = makeMountedBody(toolName: "ExitPlanMode", input: ["plan": plan])
        defer { close(window) }

        XCTAssertTrue(
            body.hasPlanBlock,
            "A non-empty v1 plan renders into the shared PermissionMonospaceScrollView.")
        XCTAssertNil(
            body.renderedEmptyHint,
            "With a plan present, the empty-plan hint branch is not taken.")
        XCTAssertEqual(
            body.planScrollMaxHeight, PermissionExitPlanModeCardBodyView.planScrollMaxHeight,
            "The plan scroll caps at 480pt (parity with SwiftUI `.frame(maxHeight: 480)`).")
        XCTAssertEqual(
            body.planScrollMaxHeight, 480,
            "480pt is the verbatim ExitPlanMode cap.")
        // headline + plan block.
        XCTAssertEqual(
            body.arrangedSubviews.count, 2,
            "v1-with-plan body = headline + monospace scroll block.")
    }

    func testV1PlanHeightClampedAtOrBelowCap() {
        // A long plan must clamp the scroll to the 480 cap rather than growing
        // unbounded and pushing the decision buttons off-screen.
        let longPlan = (1...400).map { "Step \($0): do the thing in great detail." }
            .joined(separator: "\n")
        let (body, window) = makeMountedBody(toolName: "ExitPlanMode", input: ["plan": longPlan])
        defer { close(window) }

        guard let resolved = body.planResolvedHeight else {
            return XCTFail("A v1 plan must mount a scroll block with a resolved height.")
        }
        XCTAssertGreaterThan(resolved, 0, "The clamped height is computed from settled geometry.")
        XCTAssertLessThanOrEqual(
            resolved, PermissionExitPlanModeCardBodyView.planScrollMaxHeight,
            "A long plan clamps at the 480pt cap (min(usedHeight, 480)).")
    }

    // MARK: - V2 / empty plan → hint, no scroll

    func testV2ShowsFileBackedHintAndNoScroll() {
        let (body, window) = makeMountedBody(toolName: "ExitPlanModeV2", input: [:])
        defer { close(window) }

        XCTAssertFalse(
            body.hasPlanBlock,
            "V2 stores the plan in a file we can't read — no inline scroll block.")
        XCTAssertEqual(
            body.renderedEmptyHint,
            String(
                localized:
                    "Plan stored in a file; review it in the transcript before approving."),
            "V2 renders the file-backed hint (parity with PermissionExitPlanModeCardBody.emptyPlanHint).")
        // headline + hint label.
        XCTAssertEqual(
            body.arrangedSubviews.count, 2,
            "V2 body = headline + empty-plan hint label.")
    }

    func testV2IgnoresInlinePlanCopy() {
        // The agent may still drop `plan` into rawInput on V2; the body must
        // treat the file-backed source as canonical and NOT render the stale
        // inline copy (mirrors PermissionExitPlanModeCardBodyTests.testV2IgnoresInlinePlan).
        let (body, window) = makeMountedBody(
            toolName: "ExitPlanModeV2", input: ["plan": "stale inline copy"])
        defer { close(window) }
        XCTAssertFalse(body.hasPlanBlock, "V2 must not render the inline plan as a scroll block.")
        XCTAssertEqual(
            body.renderedEmptyHint,
            String(
                localized:
                    "Plan stored in a file; review it in the transcript before approving."))
    }

    func testV1EmptyPlanShowsNoPlanHint() {
        let (body, window) = makeMountedBody(toolName: "ExitPlanMode", input: ["plan": ""])
        defer { close(window) }
        XCTAssertFalse(body.hasPlanBlock, "An empty v1 plan collapses to the hint, not an empty scroll.")
        XCTAssertEqual(
            body.renderedEmptyHint,
            String(localized: "No plan body — review the transcript before approving."),
            "An empty v1 plan shows the no-plan-body hint (parity with emptyPlanHint).")
    }

    func testV1MissingPlanKeyShowsNoPlanHint() {
        let (body, window) = makeMountedBody(toolName: "ExitPlanMode", input: [:])
        defer { close(window) }
        XCTAssertFalse(body.hasPlanBlock)
        XCTAssertEqual(
            body.renderedEmptyHint,
            String(localized: "No plan body — review the transcript before approving."))
    }
}
