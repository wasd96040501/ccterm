import AgentSDK
import XCTest

@testable import ccterm

/// Pure tests for the typewriter reveal's advance math — the rate model that
/// makes streamed text reveal one glyph at a time while finishing ≈ when the
/// stream finishes ("总时长一样"). No runtime, no ticker.
final class TypewriterRevealTests: XCTestCase {

    func testHeadAdvancesTowardTargetAndCapsAtCount() {
        var r = TypewriterReveal(messageId: "m", target: "Hello")  // 5 chars
        XCTAssertEqual(r.revealedCount, 0)
        XCTAssertFalse(r.isCaughtUp)

        // A large frame can never reveal past the received text.
        r.advance(dt: 10)
        XCTAssertEqual(r.head, 5, accuracy: 0.0001)
        XCTAssertEqual(r.revealedCount, 5)
        XCTAssertTrue(r.isCaughtUp)
    }

    func testFloorAdvancesEvenATinyBacklogOneGlyphAtATime() {
        // A 1-char backlog with a negligible catch-up term: the per-second
        // floor is what keeps it moving — exactly one glyph at 60char/s·1/60s.
        var r = TypewriterReveal(messageId: "m", target: "A")
        let params = TypewriterReveal.Params(catchUpWindow: 100, minCharsPerSecond: 60)
        r.advance(dt: 1.0 / 60.0, params: params)
        XCTAssertEqual(r.head, 1, accuracy: 0.0001)
        XCTAssertTrue(r.isCaughtUp)
    }

    func testCatchUpDominatesALargeBacklog() {
        var r = TypewriterReveal(messageId: "m", target: String(repeating: "x", count: 1000))
        let params = TypewriterReveal.Params(catchUpWindow: 0.1, minCharsPerSecond: 1)
        // remaining/window · dt = 1000 / 0.1 · (1/60) ≈ 166.7, well above the
        // floor (1 · 1/60), so the exponential term wins on a big backlog.
        r.advance(dt: 1.0 / 60.0, params: params)
        XCTAssertEqual(r.head, 1000.0 / 0.1 / 60.0, accuracy: 0.5)
    }

    func testEmptyTargetIsCaughtUpWithNoWork() {
        var r = TypewriterReveal(messageId: "m", target: "")
        r.advance(dt: 1)
        XCTAssertEqual(r.head, 0)
        XCTAssertTrue(r.isCaughtUp)
        XCTAssertFalse(r.hasWork)
    }

    func testPendingFinalizeKeepsWorkEvenWhenCaughtUp() {
        var r = TypewriterReveal(messageId: "m", target: "hi")
        r.advance(dt: 10)
        XCTAssertTrue(r.isCaughtUp)
        XCTAssertFalse(r.hasWork)

        r.pendingFinalize = (UUID(), Message2Fixtures.assistantText("hi", messageId: "m"))
        XCTAssertTrue(r.hasWork, "a parked finalize is work until the swap runs")
    }

    func testGrowingTargetReopensTheChase() {
        var r = TypewriterReveal(messageId: "m", target: "abc")
        r.advance(dt: 10)
        XCTAssertTrue(r.isCaughtUp)
        // More text arrives — the head now trails again.
        r.target = "abcdef"
        XCTAssertFalse(r.isCaughtUp)
        XCTAssertTrue(r.hasWork)
        r.advance(dt: 10)
        XCTAssertEqual(r.revealedCount, 6)
    }

    func testRevealConvergesInBoundedFramesAtDefaultParams() {
        // The whole point of the catch-up term: a fully-received target drains
        // in far fewer frames than the floor alone would take, so the visible
        // reveal finishes shortly after the stream — never a long tail.
        var r = TypewriterReveal(messageId: "m", target: String(repeating: "a", count: 300))
        var frames = 0
        while r.hasWork, frames < 1000 {
            r.advance(dt: 1.0 / 60.0)  // .default params
            frames += 1
        }
        XCTAssertTrue(r.isCaughtUp)
        // 300 chars / 60char-s floor alone = 300 frames; the catch-up term
        // collapses it well under that.
        XCTAssertLessThan(frames, 250)
    }
}
