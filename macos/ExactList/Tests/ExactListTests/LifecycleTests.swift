import ExactListTestSupport
import XCTest

@testable import ExactList

/// Mount order, loading, and the calls before it: §4.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class LifecycleTests: XCTestCase {

    func testL1_injectedNotAssigned() async throws {
        XCTFail("pending: SPEC L1")
    }

    func testL2_theListOwnsItsScrollView() async throws {
        XCTFail("pending: SPEC L2")
    }

    func testL3_nothingIsAskedBeforeTheLoadPoint() async throws {
        XCTFail("pending: SPEC L3")
    }

    func testL4_loadingIsAutomatic() async throws {
        XCTFail("pending: SPEC L4")
    }

    func testL5_callsBeforeTheLoadPointAreHarmlessAndDefined() async throws {
        XCTFail("pending: SPEC L5")
    }

    func testL6_theInitialPosition() async throws {
        XCTFail("pending: SPEC L6")
    }

    func testL7_neverMeasureAtAWidthThatWontBeShown() async throws {
        XCTFail("pending: SPEC L7")
    }

    func testL8_leavingTheWindowChangesNothing() async throws {
        XCTFail("pending: SPEC L8")
    }

    func testL9_reEntrancyIsAProgrammerError() async throws {
        XCTFail("pending: SPEC L9")
    }

    func testL10_theCountIsChecked() async throws {
        XCTFail("pending: SPEC L10")
    }

    func testL11_theInternalScrollViewIsConfiguredOneWayAndItIsFixed() async throws {
        XCTFail("pending: SPEC L11")
    }

    func testL12_invalidInputIsAProgrammerError() async throws {
        XCTFail("pending: SPEC L12")
    }
}
