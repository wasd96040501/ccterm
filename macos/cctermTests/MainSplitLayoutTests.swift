import AppKit
import XCTest

@testable import ccterm

/// The main split's geometry at the window sizes users actually run: the
/// sidebar stays inside its thickness limits, the detail pane keeps its
/// minimum, and the two panes tile the window side by side.
@MainActor
final class MainSplitLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPanesTileDefaultWindow() async {
        await assertPanesTile(size: AppKitStage.defaultWindowSize)
    }

    func testPanesTileMinimumWindow() async {
        await assertPanesTile(size: AppKitStage.minWindowSize)
    }

    private func assertPanesTile(
        size: CGSize, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let stage = AppKitStage.mainSplit(size: size)
        defer { stage.teardown() }
        await stage.settle()

        guard let split = stage.mainSplit,
            let sidebarWidth = stage.sidebarWidth,
            let detailWidth = stage.detailPaneWidth
        else {
            return XCTFail("mainSplit stage did not mount two panes", file: file, line: line)
        }
        let sidebar = split.splitViewItems[0].viewController.view
        let detail = split.splitViewItems[1].viewController.view

        XCTAssertGreaterThanOrEqual(sidebarWidth, 220 - Geometry.tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(sidebarWidth, 350 + Geometry.tolerance, file: file, line: line)
        XCTAssertGreaterThanOrEqual(detailWidth, 680 - Geometry.tolerance, file: file, line: line)
        Geometry.assertContained(sidebar, in: stage.rootView, file: file, line: line)
        Geometry.assertContained(detail, in: stage.rootView, file: file, line: line)
        Geometry.assertNoOverlap(sidebar, detail, in: stage.rootView, file: file, line: line)
    }
}
