import AppKit
import ExactListTestSupport
import XCTest

/// What `NSTableView` actually does, asserted on the OS the suite runs on. These
/// back every "Characterized" claim in `SPEC.md` §2. If one fails, AppKit
/// changed, and §2 has to change with it.
@MainActor
final class NSTableViewCharacterizationTests: XCTestCase {

    /// §2 Geometry: `reloadData()` over 10 000 rows asks for far fewer heights
    /// than there are rows, and the document height it reports before the reader
    /// scrolls differs from the sum of the heights.
    func testCharacterizesEstimatedGeometry() async throws {
        XCTFail("pending: SPEC §2 Geometry")
    }

    /// §2 Scroll position: with the viewport in the middle, inserting a row above
    /// it changes which row is at the top of the viewport.
    func testCharacterizesContentMovingOnInsertAbove() async throws {
        XCTFail("pending: SPEC §2 Scroll position")
    }

    /// §2 Setup order: a table given its data source and reloaded before layout
    /// asks for heights while its width is still 0.
    func testCharacterizesMeasuringBeforeLayout() async throws {
        XCTFail("pending: SPEC §2 Setup order")
    }
}
