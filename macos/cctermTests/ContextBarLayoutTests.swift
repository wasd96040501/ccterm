import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for `ContextBarLayout` — the SwiftUI-free
/// layout math lifted out of the private `ContextBreakdownView`
/// (`ContextRingButton.swift`; migration plan §4.2) — and the
/// `ContextBarView` (custom `draw(_:)`) that consumes it. These run on the
/// unfiltered `make test-unit` suite and drive the real production types:
///
/// - category **ordering** (active by tokens desc → deferred by tokens desc →
///   buffer → Free space, mirroring the JS reference),
/// - `displaySum` (the segment-width denominator over every visible category),
/// - `rankInActive` (the accent color-step counter),
/// - `segmentKind` (the three color *intents*: free / muted / active+opacity),
/// - laid-out `segments` (width proportion + `< 0.5%` sliver skip) and the
///   pixel `resolvedSegmentRects` the view draws,
/// - the **empty-placeholder** branch (no usage → no segments).
@MainActor
final class ContextBarLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixtures

    /// A representative breakdown: two active rows, one deferred row, the
    /// autocompact buffer, and Free space — exactly the category families the
    /// ordering / color logic distinguishes.
    ///
    /// tokens: Messages 74_600, System tools 11_600, System tools (deferred)
    /// 19_157, Autocompact buffer 33_000, Free space 869_600.
    /// displaySum = 1_007_957.
    private func representativeUsage() throws -> ContextUsage {
        let raw: [String: Any] = [
            // Deliberately NOT in display order, so the test proves the sort.
            "categories": [
                ["name": "System tools", "tokens": 11_600],
                ["name": "Free space", "tokens": 869_600],
                ["name": "Messages", "tokens": 74_600],
                ["name": "Autocompact buffer", "tokens": 33_000],
                ["name": "System tools (deferred)", "tokens": 19_157, "isDeferred": true],
            ],
            "totalTokens": 138_357,
            "maxTokens": 1_000_000,
            "rawMaxTokens": 1_000_000,
            "percentage": 14,
        ]
        return try ContextUsage(json: raw)
    }

    private static let displaySum = 74_600 + 11_600 + 19_157 + 33_000 + 869_600  // 1_007_957

    // MARK: - Ordering (active desc → deferred desc → buffer → free)

    func testOrderedPutsActiveDescThenDeferredThenBufferThenFree() throws {
        let usage = try representativeUsage()
        let names = ContextBarLayout.ordered(usage).map(\.name)
        XCTAssertEqual(
            names,
            [
                "Messages",  // active, 74_600 (desc)
                "System tools",  // active, 11_600
                "System tools (deferred)",  // deferred
                "Autocompact buffer",  // buffer
                "Free space",  // free, last
            ])
    }

    func testOrderedActiveRowsSortDescendingByTokens() throws {
        // Three active rows out of order in the payload → must come out desc.
        let raw: [String: Any] = [
            "categories": [
                ["name": "A", "tokens": 100],
                ["name": "B", "tokens": 500],
                ["name": "C", "tokens": 300],
            ],
            "rawMaxTokens": 1_000,
        ]
        let usage = try ContextUsage(json: raw)
        XCTAssertEqual(ContextBarLayout.ordered(usage).map(\.name), ["B", "C", "A"])
    }

    func testCompactBufferIsAlsoTreatedAsBuffer() throws {
        // "Compact buffer" (no "Auto" prefix) is the other buffer name.
        let raw: [String: Any] = [
            "categories": [
                ["name": "Compact buffer", "tokens": 5_000],
                ["name": "Messages", "tokens": 10_000],
                ["name": "Free space", "tokens": 1_000],
            ],
            "rawMaxTokens": 100_000,
        ]
        let usage = try ContextUsage(json: raw)
        // active (Messages) → buffer (Compact buffer) → free (Free space)
        XCTAssertEqual(
            ContextBarLayout.ordered(usage).map(\.name),
            ["Messages", "Compact buffer", "Free space"])
        XCTAssertTrue(ContextBarLayout.isBufferName("Compact buffer"))
        XCTAssertTrue(ContextBarLayout.isBufferName("Autocompact buffer"))
        XCTAssertFalse(ContextBarLayout.isBufferName("Messages"))
    }

    // MARK: - displaySum

    func testDisplaySumCountsEveryVisibleCategory() throws {
        let usage = try representativeUsage()
        let ordered = ContextBarLayout.ordered(usage)
        XCTAssertEqual(ContextBarLayout.displaySum(ordered), Self.displaySum)
    }

    func testDisplaySumFloorsAtOneForZeroTokens() throws {
        let raw: [String: Any] = [
            "categories": [["name": "Empty", "tokens": 0]],
            "rawMaxTokens": 0,
        ]
        let usage = try ContextUsage(json: raw)
        // max(1, 0) == 1 so the segment proportion divide is safe.
        XCTAssertEqual(ContextBarLayout.displaySum(ContextBarLayout.ordered(usage)), 1)
    }

    // MARK: - rankInActive (accent color-step counter)

    func testRankInActiveCountsOnlyActiveRowsAtOrBeforeIndex() throws {
        let usage = try representativeUsage()
        let ordered = ContextBarLayout.ordered(usage)
        // ordered: [Messages(active), System tools(active), deferred, buffer, free]
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 0), 0)  // Messages
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 1), 1)  // System tools
        // The deferred/buffer/free rows are not active; rankInActive returns
        // the running active count BEFORE them (no increment for non-active).
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 2), 2)  // deferred
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 3), 2)  // buffer
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 4), 2)  // free
    }

    func testRankInActiveOutOfRangeIsZero() throws {
        let usage = try representativeUsage()
        let ordered = ContextBarLayout.ordered(usage)
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: -1), 0)
        XCTAssertEqual(ContextBarLayout.rankInActive(ordered: ordered, at: 99), 0)
    }

    // MARK: - segmentKind (color intent — free / muted / active+opacity)

    func testSegmentKindClassifiesFreeMutedActive() throws {
        let usage = try representativeUsage()
        let ordered = ContextBarLayout.ordered(usage)
        func kind(_ i: Int) -> ContextBarLayout.SegmentKind {
            ContextBarLayout.segmentKind(
                for: ordered[i], rankInActive: ContextBarLayout.rankInActive(ordered: ordered, at: i))
        }
        // Messages: active rank 0 → opacity 1.0
        XCTAssertEqual(kind(0), .active(opacity: 1.0))
        // System tools: active rank 1 → opacity 1.0 - 0.12 = 0.88
        XCTAssertEqual(kind(1), .active(opacity: 0.88))
        // deferred → muted
        XCTAssertEqual(kind(2), .muted)
        // buffer → muted
        XCTAssertEqual(kind(3), .muted)
        // free → free
        XCTAssertEqual(kind(4), .free)
    }

    func testActiveOpacityStepCapsAtSixStepsAndFloors() {
        // rank 0 → 1.0; rank k → 1 - 0.12k, clamped at 6 steps (=> 0.28) but
        // floored at 0.35, so ranks ≥ 6 all read 0.35.
        func op(_ rank: Int) -> Double {
            guard
                case .active(let o) = ContextBarLayout.segmentKind(
                    for: makeActiveCategory(), rankInActive: rank)
            else { return .nan }
            return o
        }
        XCTAssertEqual(op(0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(op(1), 0.88, accuracy: 0.0001)
        XCTAssertEqual(op(2), 0.76, accuracy: 0.0001)
        XCTAssertEqual(op(5), 0.40, accuracy: 0.0001)  // 1 - 0.6 = 0.40
        // step capped at 6: 1 - 0.72 = 0.28 → floored to 0.35
        XCTAssertEqual(op(6), 0.35, accuracy: 0.0001)
        XCTAssertEqual(op(20), 0.35, accuracy: 0.0001)
    }

    // MARK: - segments (proportions + sliver skip)

    func testSegmentsProportionsMatchTokensOverDisplaySum() throws {
        let usage = try representativeUsage()
        let segments = ContextBarLayout.segments(for: usage)
        let sum = Double(Self.displaySum)
        // All five categories exceed 0.5% of the sum, so none are dropped.
        XCTAssertEqual(segments.count, 5)
        // Proportions follow the ORDERED tokens (Messages, System tools,
        // deferred, buffer, free).
        let expected = [74_600.0, 11_600.0, 19_157.0, 33_000.0, 869_600.0].map { $0 / sum }
        for (seg, want) in zip(segments, expected) {
            XCTAssertEqual(seg.proportion, want, accuracy: 0.00001)
        }
    }

    func testSegmentsDropSliversUnderHalfPercent() throws {
        // One category is < 0.5% of the sum → must be skipped (matching the
        // SwiftUI barTrack `if proportion >= 0.005`).
        // Sum = 10_000 + 30 + 5_000 = 15_030; 30/15_030 ≈ 0.002 (< 0.005).
        let raw: [String: Any] = [
            "categories": [
                ["name": "Big", "tokens": 10_000],
                ["name": "Sliver", "tokens": 30],
                ["name": "Free space", "tokens": 5_000],
            ],
            "rawMaxTokens": 100_000,
        ]
        let usage = try ContextUsage(json: raw)
        let ordered = ContextBarLayout.ordered(usage)  // Big, Sliver, Free space
        XCTAssertEqual(ordered.map(\.name), ["Big", "Sliver", "Free space"])
        let segments = ContextBarLayout.segments(for: usage)
        // Sliver dropped → only 2 segments remain.
        XCTAssertEqual(segments.count, 2)
        // The two kept segments are Big (active) + Free space.
        XCTAssertEqual(segments[0].kind, .active(opacity: 1.0))
        XCTAssertEqual(segments[1].kind, .free)
    }

    func testSegmentsExactlyAtThresholdKept() throws {
        // proportion == 0.005 must be KEPT (>= 0.005, not strictly >).
        // tokens 5 of sum 1_000 = 0.005 exactly.
        let raw: [String: Any] = [
            "categories": [
                ["name": "Edge", "tokens": 5],
                ["name": "Rest", "tokens": 995],
            ],
            "rawMaxTokens": 10_000,
        ]
        let usage = try ContextUsage(json: raw)
        let segments = ContextBarLayout.segments(for: usage)
        XCTAssertEqual(segments.count, 2, "a segment exactly at 0.5% must be kept")
    }

    // MARK: - ContextBarView consumes the helper (representative + empty)

    func testViewResolvedSegmentsMatchHelper() throws {
        let usage = try representativeUsage()
        let view = ContextBarView(usage: usage)
        // The view's cached segments equal the helper's output verbatim.
        XCTAssertEqual(view.resolvedSegments, ContextBarLayout.segments(for: usage))
        XCTAssertEqual(view.resolvedSegments.count, 5)
    }

    func testViewSegmentRectsAccumulateLeftToRight() throws {
        let usage = try representativeUsage()
        let view = ContextBarView(usage: usage)
        let width: CGFloat = 336  // ContextBreakdownView content width (360 - padding)
        let rects = view.resolvedSegmentRects(forWidth: width)
        XCTAssertEqual(rects.count, 5)

        // Pin segment[0] (Messages) to an ABSOLUTE expected pixel width derived
        // from the raw tokens / displaySum — NOT re-derived from seg.proportion.
        // If the proportion math regresses this fails; `width * seg.proportion`
        // (below) cannot, because it restates the getter's own body.
        // 336 * 74_600 / 1_007_957 ≈ 24.8677 pt.
        XCTAssertEqual(rects[0].origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(
            rects[0].width, width * 74_600 / CGFloat(Self.displaySum), accuracy: 0.001)
        XCTAssertEqual(rects[0].width, 24.8677, accuracy: 0.01)

        // Each rect width == width * proportion; x accumulates left-to-right.
        // This sweep is the SINGLE source `draw(_:)` consumes, so a regression
        // in the accumulation is both painted and caught here.
        let segs = view.resolvedSegments
        var expectedX: CGFloat = 0
        for (rect, seg) in zip(rects, segs) {
            XCTAssertEqual(rect.width, width * CGFloat(seg.proportion), accuracy: 0.001)
            XCTAssertEqual(rect.origin.x, expectedX, accuracy: 0.001)
            XCTAssertEqual(rect.height, ContextBarView.barHeight, accuracy: 0.001)
            expectedX += rect.width
        }
        // The accumulated total never exceeds the track width (all proportions
        // sum to ≤ 1 because displaySum covers every visible category).
        XCTAssertLessThanOrEqual(expectedX, width + 0.01)
    }

    func testViewEmptyPlaceholderHasNoSegments() {
        // No usage → the fetching / no-CLI placeholder: only the track paints,
        // zero segments laid out.
        let view = ContextBarView(usage: nil)
        XCTAssertTrue(view.resolvedSegments.isEmpty)
        XCTAssertTrue(view.resolvedSegmentRects(forWidth: 300).isEmpty)
    }

    func testViewClearingUsageReturnsToEmptyPlaceholder() throws {
        let view = ContextBarView(usage: try representativeUsage())
        XCTAssertEqual(view.resolvedSegments.count, 5)
        view.usage = nil
        XCTAssertTrue(view.resolvedSegments.isEmpty)
    }

    func testViewIntrinsicHeightIsBarHeightAndWidthFlexible() {
        let view = ContextBarView(usage: nil)
        XCTAssertEqual(view.intrinsicContentSize.height, ContextBarView.barHeight, accuracy: 0.001)
        XCTAssertEqual(view.intrinsicContentSize.width, NSView.noIntrinsicMetric, accuracy: 0.001)
    }

    // MARK: - Color resolution (kind → semantic NSColor) parity

    func testViewColorResolutionMapsKindsToSemanticColors() {
        XCTAssertEqual(
            ContextBarView.color(for: .free),
            NSColor.quaternaryLabelColor.withAlphaComponent(0.4))
        XCTAssertEqual(
            ContextBarView.color(for: .muted),
            NSColor.quaternaryLabelColor)
        XCTAssertEqual(
            ContextBarView.color(for: .active(opacity: 0.88)),
            NSColor.controlAccentColor.withAlphaComponent(0.88))
    }

    // MARK: - Helpers

    /// An active (non-deferred / non-buffer / non-free) category for the
    /// opacity-step test.
    private func makeActiveCategory() -> ContextUsage.Category {
        // swiftlint:disable:next force_try
        try! ContextUsage.Category(json: ["name": "Messages", "tokens": 1_000])
    }
}
