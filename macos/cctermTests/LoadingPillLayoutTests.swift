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

    func testNoUsageNoClockHasNoChip() {
        // No tokens and no clock anchor → no trailing chip at all.
        let layout = LoadingPillLayout.make(usage: .zero)
        XCTAssertNil(layout.usageRect)
        XCTAssertNil(layout.startedAt)
        XCTAssertEqual(layout.measuredWidth, BlockStyle.loadingPillWidth)
    }

    func testClockReservesChipEvenWithoutTokens() throws {
        // A turn clock alone (no tokens yet) still reserves the trailing chip,
        // sitting past the dots + gap.
        let started = Date()
        let layout = LoadingPillLayout.make(usage: .zero, startedAt: started)
        XCTAssertEqual(layout.startedAt, started)
        let rect = try XCTUnwrap(layout.usageRect)
        XCTAssertGreaterThanOrEqual(
            rect.origin.x,
            BlockStyle.loadingPillWidth + BlockStyle.loadingPillUsageGap)
        XCTAssertGreaterThan(layout.measuredWidth, BlockStyle.loadingPillWidth)
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

    func testRowHeightConstantRegardlessOfChip() {
        // Constant height is what lets setTurnUsage / setTurnStartedAt skip
        // noteHeightOfRows — true whether the chip carries a clock, tokens, both,
        // or nothing.
        let empty = LoadingPillLayout.make(usage: .zero)
        let withUsage = LoadingPillLayout.make(
            usage: TurnTokenUsage(inputTokens: 9_999_999, outputTokens: 1))
        let withClock = LoadingPillLayout.make(usage: .zero, startedAt: Date())
        let withBoth = LoadingPillLayout.make(
            usage: TurnTokenUsage(inputTokens: 9_999_999, outputTokens: 1),
            startedAt: Date())
        XCTAssertEqual(empty.totalHeight, withUsage.totalHeight)
        XCTAssertEqual(empty.totalHeight, withClock.totalHeight)
        XCTAssertEqual(empty.totalHeight, withBoth.totalHeight)
    }

    func testFormatElapsedDropsZeroUnits() {
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(0), "0s")
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(45), "45s")
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(60), "1m")
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(63), "1m 3s")
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(3661), "1h 1m 1s")
        // 1 day + 0 hours + 2 minutes + 3 seconds → the zero hour is dropped.
        XCTAssertEqual(LoadingPillUsageView.formatElapsed(86523), "1d 2m 3s")
    }

    func testDotsVerticallyCenteredInRow() {
        let layout = LoadingPillLayout.make(usage: .zero)
        let expectedY = (layout.totalHeight - BlockStyle.loadingPillHeight) / 2
        XCTAssertEqual(layout.symbolFrame.origin.y, expectedY, accuracy: 0.5)
        XCTAssertEqual(layout.symbolFrame.width, BlockStyle.loadingPillWidth)
    }
}
