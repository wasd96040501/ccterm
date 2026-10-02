import AgentSDK
import AppKit
import Combine
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// The sidebar mounted in the real main split over a synthetic library:
/// what its outline shows, what opening a row does, and what a republish
/// keeps.
@MainActor
final class SidebarViewControllerTests: XCTestCase {
    private var fixture: SessionDirectoryFixture!
    private var store: LibraryStore!
    private var stage: AppKitStage!
    private var outline: NSOutlineView!
    private var area: EditorAreaViewController!

    override func setUp() async throws {
        continueAfterFailure = false
        fixture = try SessionDirectoryFixture()
        try LibraryStoreTests.writeLibrary(fixture)
        store = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
        stage = AppKitStage.mainSplit(library: store)
        store.start()
        await waitForNodes { !$0.isEmpty }
        await stage.settle()
        outline = try XCTUnwrap(stage.find(NSOutlineView.self))
        area = try XCTUnwrap(stage.mainSplit?.splitViewItems[1].viewController as? EditorAreaViewController)
    }

    override func tearDown() async throws {
        store.stop()
        stage.teardown()
        fixture.remove()
    }

    private func waitForNodes(_ predicate: @escaping ([LibraryNode]) -> Bool) async {
        let arrived = expectation(description: "nodes")
        let subscription = store.$nodes.first(where: predicate).sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 10)
        subscription.cancel()
    }

    private func titles() -> [String] {
        (0..<outline.numberOfRows).map { row in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.objectValue as? String
                ?? "?"
        }
    }

    private func row(titled title: String) throws -> Int {
        try XCTUnwrap(titles().firstIndex(of: title), "no row titled \(title) in \(titles())")
    }

    /// What a click on the row does.
    private func select(_ title: String) throws {
        outline.selectRowIndexes([try row(titled: title)], byExtendingSelection: false)
    }

    private func tabs() -> [String] {
        area.groups.flatMap(\.tabViewItems).compactMap { $0.viewController?.title }
    }

    // MARK: - Tests

    func testShowsProjectsCollapsed() {
        XCTAssertEqual(titles(), ["repo", "other"])
    }

    func testProjectsHoldSessionsAndSessionsHoldTheirAgents() throws {
        outline.expandItem(outline.item(atRow: 0))
        outline.expandItem(outline.item(atRow: try row(titled: "Named")))
        XCTAssertEqual(titles(), ["repo", "Named", String(localized: "Subagents"), "review", "Auto", "other"])
    }

    func testSelectingSessionsShowsThemInOneTemporaryTab() throws {
        outline.expandItem(outline.item(atRow: 0))
        try select("Named")
        try select("Auto")
        XCTAssertEqual(tabs(), ["Auto"])
    }

    func testSelectingAGroupOpensNothing() throws {
        try select("repo")
        outline.expandItem(outline.item(atRow: 0))
        outline.expandItem(outline.item(atRow: try row(titled: "Named")))
        try select(String(localized: "Subagents"))
        XCTAssertEqual(tabs(), [])
    }

    func testExpansionAndSelectionSurviveARepublish() async throws {
        outline.expandItem(outline.item(atRow: 0))
        try select("Auto")

        try fixture.write(
            "-x-repo/s6.jsonl", [SessionDirectoryFixture.user("u"), SessionDirectoryFixture.aiTitle("Newer")])
        await waitForNodes { $0.first?.children.first?.title == "Newer" }
        await stage.settle()

        XCTAssertEqual(titles(), ["repo", "Newer", "Named", "Auto", "other"])
        XCTAssertEqual(outline.selectedRow, try row(titled: "Auto"))
        XCTAssertEqual(tabs(), ["Auto"])
    }

    // MARK: - Selecting a session the window already shows

    private func firstSession() throws -> LibraryNode {
        func find(_ nodes: [LibraryNode]) -> LibraryNode? {
            for node in nodes {
                if node.kind == .session { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return try XCTUnwrap(find(store.nodes))
    }

    /// A session just started in a New tab is selected in the sidebar without
    /// being opened again: its tab is the one showing.
    func testSelectingASessionTheWindowShowsReportsNothing() throws {
        let sidebar = try XCTUnwrap(stage.mainSplit?.splitViewItems[0].viewController as? SidebarViewController)
        let node = try firstSession()

        sidebar.select(transcriptAt: try XCTUnwrap(node.transcriptURL))

        XCTAssertEqual(outline.selectedRow, try row(titled: node.title), "the row was not selected")
        XCTAssertTrue(area.groups.flatMap(\.tabViewItems).isEmpty, "selecting it opened a tab")
    }

    /// One the library doesn't list yet waits; the next one it does list is
    /// selected as before.
    func testASessionTheLibraryDoesNotListYetSelectsNothing() throws {
        let sidebar = try XCTUnwrap(stage.mainSplit?.splitViewItems[0].viewController as? SidebarViewController)
        outline.deselectAll(nil)

        sidebar.select(transcriptAt: URL(fileURLWithPath: "/nowhere/not-yet.jsonl"))

        XCTAssertEqual(outline.selectedRow, -1)
    }
}
