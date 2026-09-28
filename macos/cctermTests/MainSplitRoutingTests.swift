import AppKit
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// What the sidebar's intents do to the editor area, as Xcode's navigator: a
/// transcript already open is selected where it is; selecting one shows it in
/// the temporary tab; opening one gives it a tab that stays.
@MainActor
final class MainSplitRoutingTests: XCTestCase {
    private var stage: AppKitStage!
    private var split: MainSplitViewController!
    private var sidebar: SidebarViewController!
    private var area: EditorAreaViewController!

    override func setUp() async throws {
        continueAfterFailure = false
        stage = AppKitStage.mainSplit()
        await stage.settle()
        split = try XCTUnwrap(stage.mainSplit)
        sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
        area = try XCTUnwrap(split.splitViewItems[1].viewController as? EditorAreaViewController)
    }

    override func tearDown() async throws {
        stage.teardown()
    }

    func testOpeningAnItemAddsATab() {
        split.sidebarViewController(sidebar, didOpen: session("a"))
        XCTAssertEqual(titles(), ["a"])
        XCTAssertEqual(area.activeViewController?.title, "a")
    }

    func testOpeningTwoItemsAddsTwoTabs() {
        split.sidebarViewController(sidebar, didOpen: session("a"))
        split.sidebarViewController(sidebar, didOpen: session("b"))
        XCTAssertEqual(titles(), ["a", "b"])
        XCTAssertEqual(area.activeViewController?.title, "b")
    }

    func testOpeningAnOpenItemSelectsItsTab() {
        split.sidebarViewController(sidebar, didOpen: session("a"))
        split.sidebarViewController(sidebar, didOpen: session("b"))
        split.sidebarViewController(sidebar, didOpen: session("a"))
        XCTAssertEqual(titles(), ["a", "b"])
        XCTAssertEqual(area.activeViewController?.title, "a")
    }

    func testAGroupOpensNothing() {
        let group = LibraryNode(id: "/p/s", kind: .subagents, title: "Subagents", transcriptURL: nil, children: [])
        split.sidebarViewController(sidebar, didOpen: group)
        split.sidebarViewController(sidebar, didSelect: group)
        XCTAssertEqual(titles(), [])
    }

    func testSelectingShowsEachInTheOneTemporaryTab() {
        split.sidebarViewController(sidebar, didSelect: session("a"))
        split.sidebarViewController(sidebar, didSelect: session("b"))
        XCTAssertEqual(titles(), ["b"])
        XCTAssertEqual(area.activeGroup.previewTabViewItem?.viewController?.title, "b")
    }

    func testOpeningTheTemporaryTabsItemKeepsIt() {
        split.sidebarViewController(sidebar, didSelect: session("a"))
        split.sidebarViewController(sidebar, didOpen: session("a"))
        split.sidebarViewController(sidebar, didSelect: session("b"))
        XCTAssertEqual(titles(), ["a", "b"])
        XCTAssertEqual(area.activeGroup.previewTabViewItem?.viewController?.title, "b")
    }

    func testSelectingAnOpenItemSelectsItsTab() {
        split.sidebarViewController(sidebar, didOpen: session("a"))
        split.sidebarViewController(sidebar, didOpen: session("b"))
        split.sidebarViewController(sidebar, didSelect: session("a"))
        XCTAssertEqual(titles(), ["a", "b"])
        XCTAssertEqual(area.activeViewController?.title, "a")
        XCTAssertNil(area.activeGroup.previewTabViewItem)
    }

    /// ⌘W is sent to nil. With the focus in the sidebar — outside the area —
    /// the split hands it to the area, which closes the active tab.
    func testCloseTabFromTheSidebarClosesTheActiveTab() throws {
        split.sidebarViewController(sidebar, didOpen: session("a"))
        split.sidebarViewController(sidebar, didOpen: session("b"))
        let outline = try XCTUnwrap(stage.find(NSOutlineView.self))
        XCTAssertTrue(stage.window.makeFirstResponder(outline), "premise: the sidebar has the focus")

        let closeTab = #selector(EditorAreaViewController.closeTab(_:))
        let target = try XCTUnwrap(target(of: closeTab, from: outline), "⌘W reaches nothing from the sidebar")
        XCTAssertIdentical(target, area)
        XCTAssertTrue(NSApp.sendAction(closeTab, to: target, from: nil))
        XCTAssertEqual(titles(), ["a"])
    }

    /// Where an action sent to nil lands with `responder` focused, resolved as
    /// `NSApp.target(forAction:to:from:)` resolves it in a key window — which the
    /// off-screen one never is: the first responder up the chain that implements
    /// the action or names a supplemental target for it.
    private func target(of action: Selector, from responder: NSResponder) -> AnyObject? {
        var next: NSResponder? = responder
        while let current = next {
            if current.responds(to: action) { return current }
            if let other = current.supplementalTarget(forAction: action, sender: nil) { return other as AnyObject }
            next = current.nextResponder
        }
        return nil
    }

    private func session(_ name: String) -> LibraryNode {
        let url = URL(fileURLWithPath: "/nonexistent/\(name).jsonl")
        return LibraryNode(id: url.path, kind: .session, title: name, transcriptURL: url, children: [])
    }

    private func titles() -> [String] {
        area.groups.flatMap(\.tabViewItems).compactMap { $0.viewController?.title }
    }
}
