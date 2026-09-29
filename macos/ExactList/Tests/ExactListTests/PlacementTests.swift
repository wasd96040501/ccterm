import ExactListTestSupport
import XCTest

@testable import ExactList

/// The mounted set, views and reuse: §10.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class PlacementTests: XCTestCase {

    func testP1_exactMounting() async throws {
        XCTFail("pending: SPEC P1")
    }

    func testP2_viewsAreAskedForOnlyOnArrival() async throws {
        XCTFail("pending: SPEC P2")
    }

    func testP3_didRemoveOnDeparture() async throws {
        XCTFail("pending: SPEC P3")
    }

    func testP4_reuse() async throws {
        XCTFail("pending: SPEC P4")
    }

    func testP5_rowContainersAreInternal() async throws {
        XCTFail("pending: SPEC P5")
    }

    func testP6_rowFor() async throws {
        XCTFail("pending: SPEC P6")
    }

    func testP7_onlyMountedViewsAreHandedOut() async throws {
        XCTFail("pending: SPEC P7")
    }
}
