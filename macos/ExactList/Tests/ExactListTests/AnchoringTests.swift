import ExactListTestSupport
import XCTest

@testable import ExactList

/// Tail following and reload anchoring, in a window: §6.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class AnchoringTests: XCTestCase {

    func testA8_tailFollowingDependsOnlyOnPosition() async throws {
        XCTFail("pending: SPEC A8")
    }

    func testA9_reloadData() async throws {
        XCTFail("pending: SPEC A9")
    }
}
