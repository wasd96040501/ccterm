import ExactListTestSupport
import XCTest

@testable import ExactList

/// Motion frame by frame, from presentation layers: §8.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class MotionTests: XCTestCase {

    func testM1_whichCommitsAnimate() async throws {
        XCTFail("pending: SPEC M1")
    }

    func testM3_howItIsDone() async throws {
        XCTFail("pending: SPEC M3")
    }

    func testM6_noBlankAreas() async throws {
        XCTFail("pending: SPEC M6")
    }

    func testM8_interruptionsCompose() async throws {
        XCTFail("pending: SPEC M8")
    }

    func testM9_effects() async throws {
        XCTFail("pending: SPEC M9")
    }

    func testM10_stackingOrder() async throws {
        XCTFail("pending: SPEC M10")
    }
}
