import ExactListTestSupport
import XCTest

@testable import ExactList

/// The accessibility table and rows, through the protocol: §11.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class AccessibilityTests: XCTestCase {

    func testX1_theTableElement() async throws {
        XCTFail("pending: SPEC X1")
    }

    func testX2_rowElements() async throws {
        XCTFail("pending: SPEC X2")
    }

    func testX3_unmountedRows() async throws {
        XCTFail("pending: SPEC X3")
    }

    func testX4_stableElements() async throws {
        XCTFail("pending: SPEC X4")
    }

    func testX5_notifications() async throws {
        XCTFail("pending: SPEC X5")
    }
}
