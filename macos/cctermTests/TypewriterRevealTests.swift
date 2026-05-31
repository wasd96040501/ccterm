import AgentSDK
import XCTest

@testable import ccterm

/// Pure tests for the typewriter reveal — the message-envelope wrapper around a
/// `StreamPacer`. The rate math itself is proven in `StreamPacerTests`; these
/// cover the reveal's own contract: an incremental character prefix that caps at
/// the received text, reopens its chase when the target grows, and stays "work"
/// while a finalize is parked. No runtime, no ticker.
final class TypewriterRevealTests: XCTestCase {

    private let frame = 1.0 / 60.0

    /// A fully-received target reveals incrementally (not all at once) and caps
    /// at `target.count` — the head can never pass the received text.
    func testRevealIsIncrementalAndCapsAtCount() {
        var r = TypewriterReveal(messageId: "m", target: String(repeating: "x", count: 100))
        XCTAssertEqual(r.revealedCount, 0)
        XCTAssertFalse(r.isCaughtUp)

        // One short frame reveals some but not all of the 100-char chunk.
        r.advance(dt: frame)
        XCTAssertGreaterThan(r.revealedCount, 0)
        XCTAssertLessThan(r.revealedCount, 100, "the 100-char chunk must not pop in at once")

        // Keep ticking → it converges, and never overshoots.
        var frames = 1
        while !r.isCaughtUp, frames < 600 {
            r.advance(dt: frame)
            XCTAssertLessThanOrEqual(r.revealedCount, 100)
            frames += 1
        }
        XCTAssertEqual(r.revealedCount, 100)
        XCTAssertTrue(r.isCaughtUp)
    }

    func testEmptyTargetIsCaughtUpWithNoWork() {
        var r = TypewriterReveal(messageId: "m", target: "")
        r.advance(dt: 1)
        XCTAssertEqual(r.revealedCount, 0)
        XCTAssertTrue(r.isCaughtUp)
        XCTAssertFalse(r.hasWork)
    }

    func testPendingFinalizeKeepsWorkEvenWhenCaughtUp() {
        var r = TypewriterReveal(messageId: "m", target: "hi")
        for _ in 0..<60 { r.advance(dt: frame) }
        XCTAssertTrue(r.isCaughtUp)
        XCTAssertFalse(r.hasWork)

        r.pendingFinalize = (UUID(), Message2Fixtures.assistantText("hi", messageId: "m"))
        XCTAssertTrue(r.hasWork, "a parked finalize is work until the swap runs")
    }

    func testGrowingTargetReopensTheChase() {
        var r = TypewriterReveal(messageId: "m", target: "abc")
        for _ in 0..<60 { r.advance(dt: frame) }
        XCTAssertTrue(r.isCaughtUp)

        // More text arrives — the head now trails again.
        r.target = "abcdef"
        XCTAssertFalse(r.isCaughtUp)
        XCTAssertTrue(r.hasWork)

        var frames = 0
        while !r.isCaughtUp, frames < 600 {
            r.advance(dt: frame)
            frames += 1
        }
        XCTAssertEqual(r.revealedCount, 6)
    }

    /// The point of the rate model: a fully-received target drains shortly after
    /// the stream — never a long tail. `seal()` (finalize) drops the cushion so
    /// the tail drains promptly.
    func testRevealConvergesInBoundedFrames() {
        var r = TypewriterReveal(messageId: "m", target: String(repeating: "a", count: 300))
        r.seal()
        var frames = 0
        while r.hasWork, frames < 1000 {
            r.advance(dt: frame)
            frames += 1
        }
        XCTAssertTrue(r.isCaughtUp)
        // 300 chars at the 60 char/s floor alone = 300 frames; the rate servo
        // collapses it well under that.
        XCTAssertLessThan(frames, 250)
    }
}
