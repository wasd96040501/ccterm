import Components
import DisplayModels
import XCTest

@testable import ccterm

/// Every kind of session divider, light above dark
/// (design/transcript/05-local.md). Review only — `make test-unit
/// FILTER=DividerRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/DividerRowView.png`.
@MainActor
final class DividerRowViewSnapshotTests: XCTestCase {
    func testEveryKind() {
        let models = [
            SessionDivider(
                id: "1", kind: .compacted(automatically: false, preTokens: 168_000, postTokens: 14_000), summary: "…"),
            SessionDivider(
                id: "2", kind: .compacted(automatically: true, preTokens: nil, postTokens: nil), summary: nil),
            SessionDivider(id: "3", kind: .compacting, summary: nil),
            SessionDivider(id: "4", kind: .resumed(Date(timeIntervalSinceNow: -3600 * 30)), summary: nil),
            SessionDivider(id: "5", kind: .pause(Date(timeIntervalSinceNow: -3600 * 24 * 20)), summary: nil),
        ]
        RowSnapshot.render(DividerRowView.self, models, name: "DividerRowView", test: self)
    }
}
