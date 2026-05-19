import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the enter-plan-mode body's static copy. The
/// bullets and intro/closing are product copy, not data — but
/// they're surfaced through `String(localized:)`, so the test pins
/// the resolved values against the catalog. A typo in either the
/// view or the catalog fails this test loudly.
final class PermissionEnterPlanModeCardBodyTests: XCTestCase {

    func testBulletListHasFourEntries() {
        // Upstream surfaces exactly four bullets — if we add or
        // remove one the view loses parity with the CLI. Pin the
        // count.
        XCTAssertEqual(PermissionEnterPlanModeCardBody.bullets.count, 4)
    }

    func testBulletsMatchUpstreamPhrasing() {
        // The exact strings come straight from the upstream Ink
        // layout (see EnterPlanModePermissionRequest.tsx). We assert
        // against `String(localized:)` so the test trips both an
        // English-source typo and a missing zh-Hans translation.
        XCTAssertEqual(
            PermissionEnterPlanModeCardBody.bullets,
            [
                String(localized: "Explore the codebase thoroughly"),
                String(localized: "Identify existing patterns"),
                String(localized: "Design an implementation strategy"),
                String(localized: "Present a plan for your approval"),
            ])
    }

    func testIntroAndClosingAreLocalised() {
        let body = makeBody()
        XCTAssertEqual(
            body.intro,
            String(
                localized:
                    "Claude wants to enter plan mode to explore and design an implementation approach."
            ))
        XCTAssertEqual(
            body.closing,
            String(
                localized: "No code changes will be made until you approve the plan."
            ))
        XCTAssertEqual(body.bulletHeader, String(localized: "In plan mode, Claude will:"))
    }

    // MARK: - Helpers

    private func makeBody() -> PermissionEnterPlanModeCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "plan-\(UUID().uuidString)",
            toolName: "EnterPlanMode",
            input: [:])
        return PermissionEnterPlanModeCardBody(request: req)
    }
}
