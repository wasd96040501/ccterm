import ExactListTestSupport
import XCTest

@testable import ExactList

/// Width changes from a window, a divider and an animator: §9.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class WidthChangeTests: XCTestCase {

    func testW1_handledInTheSamePass() async throws {
        XCTFail("pending: SPEC W1")
    }

    func testW3_exactInThePreparedArea() async throws {
        XCTFail("pending: SPEC W3")
    }

    func testW4_noStaleRowIsEverDisplayed() async throws {
        XCTFail("pending: SPEC W4")
    }

    func testW6_neverTwiceAtTheSameWidth() async throws {
        XCTFail("pending: SPEC W6")
    }
}
