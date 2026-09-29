import ExactListTestSupport
import XCTest

@testable import ExactList

/// Viewport and settings changes: §6.4.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ViewportChangeTests: XCTestCase {

    func testV1_viewportHeight() async throws {
        XCTFail("pending: SPEC V1")
    }

    func testV2_contentInsets() async throws {
        XCTFail("pending: SPEC V2")
    }

    func testV3_rowSpacing() async throws {
        XCTFail("pending: SPEC V3")
    }

    func testV4_turningTailFollowingOnOrOff() async throws {
        XCTFail("pending: SPEC V4")
    }

    func testV5_settingsBeforeLoading() async throws {
        XCTFail("pending: SPEC V5")
    }
}
