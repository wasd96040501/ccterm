import XCTest

@testable import ExactListCore

/// Stale bookkeeping and refresh order: §9.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class StaleRowsTests: XCTestCase {

    func testW5_staleRowsAreRefreshed() throws {
        XCTFail("pending: SPEC W5")
    }
}
