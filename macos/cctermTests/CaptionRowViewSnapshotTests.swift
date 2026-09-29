import XCTest

@testable import ccterm

/// Every caption glyph, light above dark (design/transcript/06-voices.md,
/// 07-talk.md). Review only — `make test-unit
/// FILTER=CaptionRowViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/CaptionRowView.png`.
@MainActor
final class CaptionRowViewSnapshotTests: XCTestCase {
    func testEveryGlyph() {
        let models = [
            Caption(glyph: .subagent, text: "Explore agent"),
            Caption(glyph: .session, text: "ccterm · refactor tabs"),
            Caption(glyph: .coordinator, text: "Coordinator"),
            Caption(glyph: .plugin, text: "Plugin · notifier"),
            Caption(glyph: .tile(Tile(glyph: .plan, state: .done)), text: "Plan"),
            Caption(glyph: .tile(Tile(glyph: .plan, state: .waiting)), text: "Plan · Waiting for your approval"),
        ]
        RowSnapshot.render(CaptionRowView.self, models, name: "CaptionRowView", test: self)
    }
}
