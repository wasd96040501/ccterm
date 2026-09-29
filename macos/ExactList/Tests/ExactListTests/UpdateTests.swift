import ExactListTestSupport
import XCTest

@testable import ExactList

/// Batches and commits: §7.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class UpdateTests: XCTestCase {

    func testU1_synchronousCommit() async throws {
        XCTFail("pending: SPEC U1")
    }

    func testU3_theBatchClosureReceivesAProxy() async throws {
        XCTFail("pending: SPEC U3")
    }

    func testU4_singleCalls() async throws {
        XCTFail("pending: SPEC U4")
    }

    func testU5_whenHeightsAreAsked() async throws {
        XCTFail("pending: SPEC U5")
    }

    func testU6_reloadingARowsContents() async throws {
        XCTFail("pending: SPEC U6")
    }

    func testU7_reloadData() async throws {
        XCTFail("pending: SPEC U7")
    }

    func testU8_completionHandlers() async throws {
        XCTFail("pending: SPEC U8")
    }
}
