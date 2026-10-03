import AppKit
import XCTest

@testable import Components

/// The main window's title: nothing until it has a name, the name alone
/// centred, and the branch under it once there is one.
final class MainWindowTitleViewTests: XCTestCase {
    private func labels(in view: NSView) -> [NSTextField] {
        view.subviews.compactMap { $0 as? NSTextField }
    }

    func testItShowsNothingWithoutAName() {
        let view = MainWindowTitleView()
        XCTAssertTrue(view.isHidden)
        view.title = "ccterm"
        XCTAssertFalse(view.isHidden)
        view.title = nil
        XCTAssertTrue(view.isHidden)
    }

    func testTheNameAndTheBranchAreWrittenUnderTheirFields() {
        let view = MainWindowTitleView()
        view.title = "ccterm"
        view.subtitle = "transcript-views-design"
        XCTAssertEqual(labels(in: view).map(\.stringValue), ["ccterm", "transcript-views-design"])
    }

    func testAnImageIsAlwaysThereForTheFolder() {
        let view = MainWindowTitleView()
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSImageView }.count, 1)
    }
}
