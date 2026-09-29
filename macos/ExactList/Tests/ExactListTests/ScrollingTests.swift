import ExactListTestSupport
import XCTest

@testable import ExactList

/// Scroll requests and native scrolling: §11.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ScrollingTests: XCTestCase {

    func testS1_scrollingToARow() async throws {
        XCTFail("pending: SPEC S1")
    }

    func testS2_scrollingToAPosition() async throws {
        XCTFail("pending: SPEC S2")
    }

    func testS3_scrollsAreCommits() async throws {
        XCTFail("pending: SPEC S3")
    }

    func testS4_readerScrollingStaysNative() async throws {
        XCTFail("pending: SPEC S4")
    }
}
