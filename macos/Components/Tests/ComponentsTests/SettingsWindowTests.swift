import AppKit
import XCTest

@testable import Components

/// The Settings window's content driven as its sidebar is clicked: which pane
/// shows, what the window is told, and back and forward.
final class SettingsWindowTests: XCTestCase {
    private let first = NSViewController.stub()
    private let second = NSViewController.stub()
    private var split: SettingsSplitViewController!
    private var shown: [String] = []

    override func setUp() {
        split = SettingsSplitViewController(
            panes: [
                .init(title: "General", symbolName: "gearshape", viewController: first),
                .init(title: "Accounts", symbolName: "person.crop.circle", viewController: second),
            ], initial: 1)
        split.delegate = self
        split.view.frame = NSRect(x: 0, y: 0, width: 880, height: 680)
        split.view.layoutSubtreeIfNeeded()
    }

    private func table() throws -> NSTableView {
        func find(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(split.view))
    }

    private func canGo(_ action: Selector) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        return split.validateUserInterfaceItem(item)
    }

    func testItOpensOnTheInitialPaneSelected() throws {
        XCTAssertEqual(shown, ["Accounts"])
        XCTAssertNotNil(second.view.superview)
        XCTAssertEqual(try table().selectedRow, 1)
        XCTAssertFalse(canGo(#selector(SettingsSplitViewController.goBack(_:))))
    }

    func testAClickShowsThePaneAndBackAndForwardWalkTheVisits() throws {
        try table().selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertEqual(shown, ["Accounts", "General"])
        XCTAssertNotNil(first.view.superview)
        XCTAssertTrue(canGo(#selector(SettingsSplitViewController.goBack(_:))))

        split.goBack(nil)
        XCTAssertEqual(shown.last, "Accounts")
        XCTAssertEqual(try table().selectedRow, 1)
        XCTAssertTrue(canGo(#selector(SettingsSplitViewController.goForward(_:))))

        split.goForward(nil)
        XCTAssertEqual(shown.last, "General")
        XCTAssertEqual(try table().selectedRow, 0)
    }
}

extension SettingsWindowTests: SettingsSplitViewControllerDelegate {
    func settingsSplitViewController(
        _ split: SettingsSplitViewController, didShow pane: SettingsSplitViewController.Pane
    ) {
        shown.append(pane.title)
    }
}

extension NSViewController {
    /// A controller with an empty view, standing in for a pane.
    fileprivate static func stub() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }
}
