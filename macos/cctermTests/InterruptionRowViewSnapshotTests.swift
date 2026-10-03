import Components
import XCTest

@testable import ccterm

/// The interruption mark, light above dark (design/transcript/05-local.md).
/// Review only — `make test-unit FILTER=InterruptionRowViewSnapshotTests`,
/// then open `/tmp/ccterm-screenshots/InterruptionRowView.png`.
@MainActor
final class InterruptionRowViewSnapshotTests: XCTestCase {
    func testTheMark() {
        RowSnapshot.render(InterruptionRowView.self, [()], name: "InterruptionRowView", test: self)
    }
}
