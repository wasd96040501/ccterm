import ExactListTestSupport
import XCTest

@testable import ExactList

/// Queries in the list's own coordinates: §5.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class GeometryTests: XCTestCase {

    func testG4_queries() async throws {
        XCTFail("pending: SPEC G4")
    }
}
