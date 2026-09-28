import AppKit
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// What opening a sidebar item does to the editor area: a transcript opens as
/// a tab, once — opening it again selects the tab that already shows it.
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
        XCTAssertEqual(titles(), [])
    }

    private func session(_ name: String) -> LibraryNode {
        let url = URL(fileURLWithPath: "/nonexistent/\(name).jsonl")
        return LibraryNode(id: url.path, kind: .session, title: name, transcriptURL: url, children: [])
    }

    private func titles() -> [String] {
        area.groups.flatMap(\.tabViewItems).compactMap { $0.viewController?.title }
    }
}
