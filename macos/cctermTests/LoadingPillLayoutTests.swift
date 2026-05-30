import AppKit
import XCTest

@testable import ccterm

/// Pure-logic tests for `LoadingPillLayout` — the running pill that now hosts
/// a live turn-usage label. The key invariant is that row height is constant
/// whether or not a usage label is present, so `setTurnUsage` never triggers
/// `noteHeightOfRows`.
final class LoadingPillLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNoUsageHasNoLabel() {
        let layout = LoadingPillLayout.make(usage: .zero)
        XCTAssertNil(layout.usageRect)
        XCTAssertEqual(layout.measuredWidth, BlockStyle.loadingPillWidth)
    }

    func testUsageProducesRectToTheRightOfDots() throws {
        let usage = TurnTokenUsage(inputTokens: 1234, outputTokens: 340)
        let layout = LoadingPillLayout.make(usage: usage)
        // The raw totals carry through; the view renders the `↑in ↓out` label.
        XCTAssertEqual(layout.usage.compactLabel, "↑1.2k ↓340")
        // The usage view's band sits past the dots + gap.
        let rect = try XCTUnwrap(layout.usageRect)
        XCTAssertGreaterThanOrEqual(
            rect.origin.x,
            BlockStyle.loadingPillWidth + BlockStyle.loadingPillUsageGap)
        XCTAssertGreaterThan(layout.measuredWidth, BlockStyle.loadingPillWidth)
    }

    func testRowHeightConstantRegardlessOfUsage() {
        // Constant height is what lets setTurnUsage skip noteHeightOfRows.
        let empty = LoadingPillLayout.make(usage: .zero)
        let withUsage = LoadingPillLayout.make(
            usage: TurnTokenUsage(inputTokens: 9_999_999, outputTokens: 1))
        XCTAssertEqual(empty.totalHeight, withUsage.totalHeight)
    }

    func testDotsVerticallyCenteredInRow() {
        let layout = LoadingPillLayout.make(usage: .zero)
        let expectedY = (layout.totalHeight - BlockStyle.loadingPillHeight) / 2
        XCTAssertEqual(layout.symbolFrame.origin.y, expectedY, accuracy: 0.5)
        XCTAssertEqual(layout.symbolFrame.width, BlockStyle.loadingPillWidth)
    }
}
