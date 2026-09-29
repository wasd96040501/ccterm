import XCTest

@testable import ccterm

/// The interruption mark, light above dark (design/transcript/05-local.md).
/// Review only — `make test-unit FILTER=InterruptionRowViewSnapshotTests`,
/// then open `/tmp/ccterm-screenshots/InterruptionRowView.png`.
@MainActor
final class InterruptionRowViewSnapshotTests: XCTestCase {
    func testTheMark() {
        let (image, _) = SmallRowSnapshot.render([()], of: InterruptionRowView.self, name: "InterruptionRowView")
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
