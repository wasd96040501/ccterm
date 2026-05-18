import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the exit-plan-mode body's input handling. The
/// v1 / V2 branch is the load-bearing detail: v1 inlines the plan
/// in `rawInput.plan`, V2 stores it elsewhere and the body must
/// fall back to a hint rather than render an empty scroll.
final class PermissionExitPlanModeCardBodyTests: XCTestCase {

    func testV1PlanIsSurfaced() {
        let body = makeBody(
            toolName: "ExitPlanMode",
            input: ["plan": "1. Refactor auth\n2. Add tests"])
        XCTAssertFalse(body.isV2)
        XCTAssertEqual(body.plan, "1. Refactor auth\n2. Add tests")
    }

    func testV1EmptyPlanIsNil() {
        let body = makeBody(toolName: "ExitPlanMode", input: ["plan": ""])
        XCTAssertNil(body.plan)
        XCTAssertEqual(
            body.emptyPlanHint,
            String(localized: "No plan body — review the transcript before approving."))
    }

    func testV2IgnoresInlinePlan() {
        // The agent might still drop `plan` into rawInput on V2 (PR
        // #10394 upstream did exactly that for hook plumbing), but
        // the body should treat the file-based source as canonical.
        // Rendering the inline copy would mislead the user.
        let body = makeBody(
            toolName: "ExitPlanModeV2",
            input: ["plan": "stale inline copy"])
        XCTAssertTrue(body.isV2)
        XCTAssertNil(body.plan)
        XCTAssertEqual(
            body.emptyPlanHint,
            String(
                localized:
                    "Plan stored in a file; review it in the transcript before approving."
            ))
    }

    func testHeadlineIsLocalised() {
        let body = makeBody(toolName: "ExitPlanMode", input: [:])
        XCTAssertEqual(
            body.headline, String(localized: "Review the plan to leave plan mode?"))
    }

    // MARK: - Helpers

    private func makeBody(
        toolName: String, input: [String: Any]
    )
        -> PermissionExitPlanModeCardBody
    {
        let req = PermissionRequest.makePreview(
            requestId: "exit-\(UUID().uuidString)",
            toolName: toolName,
            input: input)
        return PermissionExitPlanModeCardBody(request: req)
    }
}
