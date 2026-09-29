import AppKit
import XCTest

@testable import ccterm

/// *Show N more*, light and dark. Review only —
/// `make test-unit FILTER=ShowMoreRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/ShowMoreRowView.png`.
@MainActor
final class ShowMoreRowViewSnapshotTests: XCTestCase {
    func testEveryShape() {
        RowSnapshot.render(
            ShowMoreRowView.self, [1, 85].map { .init(runID: "r", hidden: $0) }, width: 520, gap: 2,
            name: "ShowMoreRowView", test: self)
    }
}
