import XCTest

@testable import ccterm

/// The plan's decision buttons, light above dark (design/transcript/07-talk.md
/// "ExitPlanMode"). Review only — `make test-unit
/// FILTER=PlanDecisionRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/PlanDecisionRowView.png`.
@MainActor
final class PlanDecisionRowViewSnapshotTests: XCTestCase {
    func testTheButtons() {
        let (image, _) = SmallRowSnapshot.render(["plan-1"], of: PlanDecisionRowView.self, name: "PlanDecisionRowView")
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
