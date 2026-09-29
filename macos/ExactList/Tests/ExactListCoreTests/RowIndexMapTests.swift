import XCTest

@testable import ExactListCore

/// NSTableView's incremental index rules against a naive array replay: §7.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
final class RowIndexMapTests: XCTestCase {

    func testU2_nsTableViewsIndexSemantics() throws {
        XCTFail("pending: SPEC U2")
    }
}
