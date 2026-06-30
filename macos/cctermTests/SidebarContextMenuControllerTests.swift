import AppKit
import XCTest

@testable import ccterm

/// Behavioral tests for `SidebarContextMenuController` — the right-click
/// context-menu logic extracted out of `SidebarViewController`.
///
/// The controller is driven through its real, configured surface: the menu
/// items it builds (their `target` + `action`) are fired through
/// `NSApplication.sendAction`, and `menuNeedsUpdate(_:)` is invoked as
/// `NSMenuDelegate` would. Row state is supplied through the same injected
/// closures the VC wires (`nodeAtRow` / `clickedRow` / `selectedRow`), so the
/// tests exercise the production code path without any test-only seam.
///
/// In-memory dependencies only (per `cctermTests/CLAUDE.md`): a fresh
/// `InMemorySessionRepository` + `SessionManager`, a `SidebarSessionGroupOrderStore`
/// on a unique `UserDefaults` suite, a fresh `OpenInAppService`. No `.shared`,
/// no `NotificationCenter.default`, no writes to `~/.claude` / `~/.cache`.
@MainActor
final class SidebarContextMenuControllerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        suiteName = "ccterm.tests.contextmenu.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - Fixtures

    /// Build a fresh context backed by an in-memory repository pre-seeded with
    /// the given records. The model's starting selection is configurable so the
    /// archive-selection tests can set up the precondition.
    private func makeContext(
        records: [SessionRecord],
        selection: MainSelection = .newSession
    ) -> (SidebarContext, SessionManager, MainSelectionModel) {
        let repo = InMemorySessionRepository()
        for record in records { repo.save(record) }
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() },
            worktreeArchive: { _ in },
            worktreeRestore: { _ in })
        let model = MainSelectionModel()
        model.selection = selection
        let groupOrderStore = SidebarSessionGroupOrderStore(
            defaults: defaults, key: "groupOrder")
        let context = SidebarContext(
            model: model,
            sessionManager: manager,
            groupOrderStore: groupOrderStore,
            openInService: OpenInAppService())
        return (context, manager, model)
    }

    /// A history node carrying `sessionId`, mirroring what `SidebarTreeModel`
    /// produces for a history row.
    private func historyNode(_ sessionId: String, fallback: String = "Untitled") -> SidebarItemNode {
        SidebarItemNode(
            kind: .history(sessionId: sessionId, fallbackTitle: fallback, isDraft: false),
            selection: .session(sessionId))
    }

    /// A fixed (non-history) node — used to assert the menu hides for rows that
    /// aren't sessions.
    private func fixedNode() -> SidebarItemNode {
        SidebarItemNode(kind: .fixed(.newSession), selection: .newSession)
    }

    /// Construct a controller whose injected closures return `nodes[row]` for
    /// `nodeAtRow`, and the supplied `clickedRow` / `selectedRow`.
    private func makeController(
        context: SidebarContext,
        nodes: [Int: SidebarItemNode],
        clicked: Int,
        selected: Int = -1
    ) -> SidebarContextMenuController {
        SidebarContextMenuController(
            context: context,
            nodeAtRow: { nodes[$0] },
            clickedRow: { clicked },
            selectedRow: { selected })
    }

    /// Fire a menu item's configured `action` on its `target`, mirroring what
    /// AppKit does when the user picks the item. Returns whether the action was
    /// dispatched.
    @discardableResult
    private func fire(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: - Archive

    func testArchiveRoutesThroughSessionManager() {
        let sid = UUID().uuidString
        let (context, manager, _) = makeContext(
            records: [SessionRecord(sessionId: sid, title: "Real", cwd: "/x/proj", status: .created)])
        let controller = makeController(
            context: context, nodes: [0: historyNode(sid)], clicked: 0)

        XCTAssertTrue(manager.records.contains { $0.sessionId == sid })

        fire(controller.menu.items[0])  // Archive

        // After archive, the row leaves the live records set and surfaces in
        // the archived set (the manager refreshes both inside `archive`).
        XCTAssertFalse(manager.records.contains { $0.sessionId == sid })
        XCTAssertTrue(manager.archivedRecords.contains { $0.sessionId == sid })
    }

    func testArchiveOfSelectedSessionResetsSelectionToNewSession() {
        let sid = UUID().uuidString
        let (context, _, model) = makeContext(
            records: [SessionRecord(sessionId: sid, title: "Real", cwd: "/x/proj", status: .created)],
            selection: .session(sid))
        let controller = makeController(
            context: context, nodes: [0: historyNode(sid)], clicked: 0)

        fire(controller.menu.items[0])  // Archive

        XCTAssertEqual(model.selection, .newSession)
    }

    func testArchiveOfNonSelectedDoesNotChangeSelection() {
        let archivedSid = UUID().uuidString
        let otherSid = UUID().uuidString
        let (context, _, model) = makeContext(
            records: [
                SessionRecord(sessionId: archivedSid, title: "A", cwd: "/x/a", status: .created),
                SessionRecord(sessionId: otherSid, title: "B", cwd: "/x/b", status: .created),
            ],
            selection: .session(otherSid))
        let controller = makeController(
            context: context, nodes: [0: historyNode(archivedSid)], clicked: 0)

        fire(controller.menu.items[0])  // Archive the non-selected row.

        XCTAssertEqual(model.selection, .session(otherSid))
    }

    func testArchiveFallsBackToSelectedRowWhenNoClickedRow() {
        // `clickedRow == -1` (no right-clicked row) → archive uses
        // `selectedRow`, matching the VC's original fallback rule.
        let sid = UUID().uuidString
        let (context, manager, _) = makeContext(
            records: [SessionRecord(sessionId: sid, title: "Real", cwd: "/x/proj", status: .created)])
        let controller = makeController(
            context: context, nodes: [2: historyNode(sid)], clicked: -1, selected: 2)

        fire(controller.menu.items[0])  // Archive

        XCTAssertFalse(manager.records.contains { $0.sessionId == sid })
    }

    // MARK: - Copy Session File Path

    func testCopySessionFilePathIsNoOpWhenNoJSONLOnDisk() {
        // No JSONL exists for a fresh sessionId, so `HistoryLoader.locate`
        // returns nil and the action writes nothing. We assert the pasteboard
        // is left untouched by stamping a sentinel first and confirming it
        // survives. (The success path resolves through the real `~/.claude`
        // root, which the test conventions forbid touching; see notes.)
        let sid = UUID().uuidString
        let (context, _, _) = makeContext(
            records: [SessionRecord(sessionId: sid, title: "Real", cwd: "/x/proj", status: .created)])
        let controller = makeController(
            context: context, nodes: [0: historyNode(sid)], clicked: 0)

        let sentinel = "sentinel-\(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)

        fire(controller.menu.items[1])  // Copy Session File Path

        XCTAssertEqual(pasteboard.string(forType: .string), sentinel)
    }

    // MARK: - menuNeedsUpdate

    func testMenuNeedsUpdateHidesItemsForNonHistoryRow() {
        let (context, _, _) = makeContext(records: [])
        let controller = makeController(
            context: context, nodes: [0: fixedNode()], clicked: 0)

        controller.menuNeedsUpdate(controller.menu)

        XCTAssertTrue(controller.menu.items.allSatisfy { $0.isHidden })
    }

    func testMenuNeedsUpdateHidesItemsWhenNoRowClicked() {
        let (context, _, _) = makeContext(records: [])
        let controller = makeController(
            context: context, nodes: [:], clicked: -1)

        controller.menuNeedsUpdate(controller.menu)

        XCTAssertTrue(controller.menu.items.allSatisfy { $0.isHidden })
    }

    func testMenuNeedsUpdateShowsAndConfiguresForHistoryRow() {
        let sid = UUID().uuidString
        let (context, _, _) = makeContext(
            records: [SessionRecord(sessionId: sid, title: "Real", cwd: "/x/proj", status: .created)])
        let controller = makeController(
            context: context, nodes: [0: historyNode(sid)], clicked: 0)

        controller.menuNeedsUpdate(controller.menu)

        // All three items become visible for a history row.
        XCTAssertTrue(controller.menu.items.allSatisfy { !$0.isHidden })

        // "Copy Session File Path" is disabled — no JSONL on disk for a fresh
        // sessionId, so `jsonlPath` returns nil.
        let copyItem = controller.menu.items[1]
        XCTAssertFalse(copyItem.isEnabled)

        // "Open in" is disabled — the OpenInAppService hasn't resolved any
        // targets (no `refresh()` ran) and `/x/proj` doesn't exist on disk.
        let openInItem = controller.menu.items[2]
        XCTAssertFalse(openInItem.isEnabled)
        XCTAssertEqual(openInItem.submenu?.items.count, 0)
    }
}
