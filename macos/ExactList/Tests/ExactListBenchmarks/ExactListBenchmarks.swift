import ExactListTestSupport
import XCTest

@testable import ExactList

/// The same workloads against ExactList and `NSTableView`, `-O` only: §13.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class ExactListBenchmarks: XCTestCase {

    func testB1_scrolling() async throws {
        XCTFail("pending: SPEC B1")
    }

    func testB2_updates() async throws {
        XCTFail("pending: SPEC B2")
    }

    func testB3_widthChanges() async throws {
        XCTFail("pending: SPEC B3")
    }

    func testB4_loading() async throws {
        XCTFail("pending: SPEC B4")
    }
}
