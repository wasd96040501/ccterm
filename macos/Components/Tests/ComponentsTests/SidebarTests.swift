import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The sidebar, driven through `show(_:)` and its delegate and read off its
/// outline: what it lists, what a republish keeps, what it reports, and the
/// marks it draws.
@MainActor
final class SidebarTests: XCTestCase {
    private typealias Activity = SidebarActivity

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/x/\(name).jsonl") }

    private static func session(_ name: String, worktree: String? = nil) -> SidebarNode {
        SidebarNode(
            id: url(name).path, title: name, toolTip: name, glyph: .session, transcriptURL: url(name),
            worktreeCaption: worktree)
    }

    private static func project(_ name: String, _ children: [SidebarNode]) -> SidebarNode {
        SidebarNode(id: "/\(name)", title: name, toolTip: "/\(name)", glyph: .folder, children: children)
    }

    private static let nodes = [
        project("repo", [session("A"), session("B"), session("C")]),
        project("other", [session("D")]),
    ]

    private var sidebar: SidebarViewController!
    private var window: NSWindow!
    private var outline: NSOutlineView!
    private let recorder = Recorder()

    override func setUp() async throws {
        continueAfterFailure = false
        sidebar = SidebarViewController()
        sidebar.delegate = recorder
        window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 280, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentViewController = sidebar
        window.setContentSize(NSSize(width: 280, height: 400))
        window.alphaValue = 0.01
        window.orderFront(nil)
        outline = try XCTUnwrap(find(NSOutlineView.self, in: sidebar.view).first)
    }

    override func tearDown() async throws {
        window.close()
    }

    private func find<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let view = view as? V { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func drain() {
        sidebar.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

    /// The label of the mark the row shows, `nil` when it shows none.
    private func mark(row: Int) -> String? {
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
        func find(_ view: NSView) -> String? {
            if view.isAccessibilityElement(), view.accessibilityRole() == .image, !view.isHidden {
                return view.accessibilityLabel()
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(cell)
    }

    // MARK: - Loading

    func testNilIsStillLoadingAndAnyTreeIsNot() {
        sidebar.show(nil)
        drain()
        let spinner = find(NSProgressIndicator.self, in: sidebar.view).first
        XCTAssertEqual(spinner?.isHiddenOrHasHiddenAncestor, false)
        XCTAssertEqual(outline.numberOfRows, 0)

        sidebar.show(Self.nodes)
        drain()
        XCTAssertEqual(spinner?.isHiddenOrHasHiddenAncestor, true)
        XCTAssertEqual(outline.numberOfRows, 2)
    }

    func testAViewNeverToldAnythingIsLoading() {
        drain()
        XCTAssertEqual(find(NSProgressIndicator.self, in: sidebar.view).first?.isHiddenOrHasHiddenAncestor, false)
    }

    // MARK: - Rows

    func testShowsProjectsCollapsedAndTheirChildrenWhenOpened() {
        sidebar.show(Self.nodes)
        drain()
        XCTAssertEqual(titles(), ["repo", "other"])
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(titles(), ["repo", "A", "B", "C", "other"])
    }

    func testARowCarriesItsToolTipAndItsWorktreeGlyphOnlyWhenItHasABranch() throws {
        sidebar.show([Self.project("repo", [Self.session("plain"), Self.session("tree", worktree: "on branch x")])])
        drain()
        outline.expandItem(outline.item(atRow: 0))
        func glyph(row: Int) -> NSImageView? {
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            return cell.flatMap { find(NSImageView.self, in: $0).first { $0.toolTip != nil } }
        }
        XCTAssertEqual(outline.view(atColumn: 0, row: 0, makeIfNecessary: true)?.toolTip, "/repo")
        XCTAssertNil(glyph(row: 1), "a plain session has no glyph")
        let tree = try XCTUnwrap(glyph(row: 2))
        XCTAssertFalse(tree.isHidden)
        XCTAssertEqual(tree.toolTip, "on branch x")
    }

    // MARK: - Republish

    func testExpansionAndSelectionSurviveARepublish() throws {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        outline.selectRowIndexes([try row(titled: "C")], byExtendingSelection: false)

        sidebar.show([
            Self.project("repo", [Self.session("New"), Self.session("A"), Self.session("B"), Self.session("C")]),
            Self.project("other", [Self.session("D")]),
        ])
        drain()

        XCTAssertEqual(titles(), ["repo", "New", "A", "B", "C", "other"])
        XCTAssertEqual(outline.selectedRow, try row(titled: "C"))
        XCTAssertEqual(recorder.selected.map(\.title), ["C"], "restoring the selection reported it again")
    }

    func testASessionSelectedBeforeTheTreeListsItIsSelectedWhenItDoesWithoutBeingReported() throws {
        sidebar.show(Self.nodes)
        drain()
        sidebar.select(transcriptAt: Self.url("Later"))
        XCTAssertEqual(outline.selectedRow, -1)

        sidebar.show([Self.project("repo", [Self.session("Later")])])
        drain()
        XCTAssertEqual(outline.selectedRow, try row(titled: "Later"))
        XCTAssertTrue(recorder.selected.isEmpty)
    }

    // MARK: - Reports

    func testSelectingASessionReportsItAndSelectingAGroupDoesNot() throws {
        sidebar.show(Self.nodes)
        drain()
        outline.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(recorder.selected.isEmpty)
        outline.expandItem(outline.item(atRow: 0))
        outline.selectRowIndexes([try row(titled: "B")], byExtendingSelection: false)
        XCTAssertEqual(recorder.selected.map(\.id), [Self.url("B").path])
        XCTAssertEqual(recorder.selected.first?.transcriptURL, Self.url("B"))
    }

    func testDoubleClickingASessionOpensIt() throws {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        doubleClick(row: try row(titled: "B"))
        XCTAssertEqual(recorder.opened.map(\.id), [Self.url("B").path])
    }

    func testDoubleClickingAGroupTogglesItAndReportsNothing() {
        sidebar.show(Self.nodes)
        drain()
        doubleClick(row: 0)
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertTrue(recorder.selected.isEmpty)
        // The toggle animates; its end state is what matters.
        let deadline = Date().addingTimeInterval(5)
        while !outline.isItemExpanded(outline.item(atRow: 0)), Date() < deadline { drain() }
        XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: 0)))
    }

    private func doubleClick(row: Int) {
        let rect = outline.convert(outline.rect(ofRow: row), to: nil)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        func event(_ type: NSEvent.EventType, count: Int = 2) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        // A click, then the second of a double: the first one is what a window not yet
        // clicked in takes to find its row.
        window.makeFirstResponder(outline)
        for count in 1...2 {
            NSApp.postEvent(event(.leftMouseUp, count: count), atStart: false)
            outline.mouseDown(with: event(.leftMouseDown, count: count))
        }
        drain()
    }

    // MARK: - Roll-up

    func testTheMostUrgentIsARequestThenAFailureThenWorkThenAnOpenSession() {
        let failed = Activity.failed(message: "boom")
        XCTAssertEqual(Activity.mostUrgent(of: [.idle, .responding, failed, .needsInput]), .needsInput)
        XCTAssertEqual(Activity.mostUrgent(of: [.idle, .responding, failed]), failed)
        XCTAssertEqual(Activity.mostUrgent(of: [.idle, .responding]), .responding)
        XCTAssertEqual(Activity.mostUrgent(of: [.idle]), .idle)
        XCTAssertNil(Activity.mostUrgent(of: [Activity]()))
    }

    func testAGroupRollsUpEverySessionUnderIt() {
        let rolled = [Self.url("A"): Activity.idle, Self.url("C"): .responding, Self.url("D"): .needsInput]
        XCTAssertEqual(Self.nodes[0].mostUrgentActivity(in: rolled), .responding)
        XCTAssertEqual(Self.nodes[1].mostUrgentActivity(in: rolled), .needsInput)
        XCTAssertNil(Self.nodes[0].mostUrgentActivity(in: [:]))
    }

    // MARK: - Marks

    func testARowAtRestShowsNoMark() {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual((0..<outline.numberOfRows).map(mark(row:)), [nil, nil, nil, nil, nil])
    }

    func testEachLiveSessionShowsItsOwnMark() {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        sidebar.show([Self.url("A"): .idle, Self.url("B"): .responding, Self.url("C"): .failed(message: "x")])
        drain()
        XCTAssertEqual(
            (1...3).map(mark(row:)),
            [Activity.idle, .responding, .failed(message: "x")].map { Optional($0.accessibilityLabel) })
    }

    func testACollapsedGroupShowsItsMostUrgentSessionsMarkAndAnOpenOneLeavesThemToTheSessions() {
        sidebar.show(Self.nodes)
        drain()
        sidebar.show([Self.url("A"): .idle, Self.url("B"): .needsInput])
        drain()
        XCTAssertEqual(mark(row: 0), Activity.needsInput.accessibilityLabel)
        XCTAssertNil(mark(row: 1))

        outline.expandItem(outline.item(atRow: 0))
        drain()
        XCTAssertNil(mark(row: 0))
        XCTAssertEqual(mark(row: 1), Activity.idle.accessibilityLabel)
        XCTAssertEqual(mark(row: 2), Activity.needsInput.accessibilityLabel)

        outline.collapseItem(outline.item(atRow: 0))
        drain()
        XCTAssertEqual(mark(row: 0), Activity.needsInput.accessibilityLabel)
    }

    func testAMarkFollowsItsSessionAndGoesWhenTheSessionDoes() {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        sidebar.show([Self.url("A"): .responding])
        drain()
        XCTAssertEqual(mark(row: 1), Activity.responding.accessibilityLabel)
        sidebar.show([Self.url("A"): .needsInput])
        drain()
        XCTAssertEqual(mark(row: 1), Activity.needsInput.accessibilityLabel)
        sidebar.show([:])
        drain()
        XCTAssertNil(mark(row: 1))
    }

    // MARK: - Menu

    private func menu(forRow row: Int) -> NSMenu? {
        let rect = outline.convert(outline.rect(ofRow: row), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1)
        guard let menu = event.flatMap({ outline.menu(for: $0) }) else { return nil }
        // What AppKit does as the menu opens, once the click has set `clickedRow`.
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    func testALiveSessionsMenuEndsIt() throws {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        sidebar.show([Self.url("B"): .responding])
        drain()

        let menu = try XCTUnwrap(menu(forRow: 2))
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(menu.items.count, 1)
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(recorder.ended.map(\.title), ["B"])
    }

    func testARowAtRestAndAGroupHaveNoMenu() {
        sidebar.show(Self.nodes)
        drain()
        outline.expandItem(outline.item(atRow: 0))
        sidebar.show([Self.url("B"): .idle])
        drain()
        XCTAssertEqual(menu(forRow: 1)?.items.count, 0)
        XCTAssertEqual(menu(forRow: 0)?.items.count, 0)
    }
}

private final class Recorder: SidebarViewControllerDelegate {
    var selected: [SidebarNode] = []
    var opened: [SidebarNode] = []
    var ended: [SidebarNode] = []
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: SidebarNode) { selected.append(node) }
    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: SidebarNode) { opened.append(node) }
    func sidebarViewController(_ sidebar: SidebarViewController, didRequestEndOf node: SidebarNode) {
        ended.append(node)
    }
}
