import AppKit
import Combine
import XCTest

@testable import ccterm

/// The sidebar's activity marks: the roll-up of a group's sessions, what a row
/// draws as activities arrive, and End Session in a live row's menu.
@MainActor
final class SidebarActivityTests: XCTestCase {
    private typealias Activity = SessionState.Activity

    private static func session(_ name: String) -> LibraryNode {
        LibraryNode(
            id: "/x/\(name).jsonl", kind: .session, title: name,
            transcriptURL: URL(fileURLWithPath: "/x/\(name).jsonl"), children: [])
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/x/\(name).jsonl") }

    private static let nodes = [
        LibraryNode(
            id: "/x", kind: .project, title: "repo", transcriptURL: nil,
            children: [session("A"), session("B"), session("C")]),
        LibraryNode(id: "/y", kind: .project, title: "other", transcriptURL: nil, children: [session("D")]),
    ]

    private let activities = CurrentValueSubject<[URL: Activity], Never>([:])
    private var sidebar: SidebarViewController!
    private var stage: AppKitStage!
    private var outline: NSOutlineView!

    override func setUp() async throws {
        continueAfterFailure = false
        sidebar = SidebarViewController(
            nodes: Just(Self.nodes).eraseToAnyPublisher(), activities: activities.eraseToAnyPublisher())
        stage = AppKitStage.mount(sidebar, size: CGSize(width: 280, height: 400))
        stage.drain()
        outline = try XCTUnwrap(stage.find(NSOutlineView.self))
    }

    override func tearDown() async throws {
        stage.teardown()
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

    // MARK: - Rows

    func testARowAtRestShowsNoMark() {
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual((0..<outline.numberOfRows).map(mark(row:)), [nil, nil, nil, nil, nil])
    }

    func testEachLiveSessionShowsItsOwnMark() {
        outline.expandItem(outline.item(atRow: 0))
        activities.send([Self.url("A"): .idle, Self.url("B"): .responding, Self.url("C"): .failed(message: "x")])
        stage.drain()
        XCTAssertEqual(
            (1...3).map(mark(row:)),
            [Activity.idle, .responding, .failed(message: "x")].map { Optional($0.label) })
    }

    func testACollapsedGroupShowsItsMostUrgentSessionsMarkAndAnOpenOneLeavesThemToTheSessions() {
        activities.send([Self.url("A"): .idle, Self.url("B"): .needsInput])
        stage.drain()
        XCTAssertEqual(mark(row: 0), Activity.needsInput.label)
        XCTAssertNil(mark(row: 1))

        outline.expandItem(outline.item(atRow: 0))
        stage.drain()
        XCTAssertNil(mark(row: 0))
        XCTAssertEqual(mark(row: 1), Activity.idle.label)
        XCTAssertEqual(mark(row: 2), Activity.needsInput.label)

        outline.collapseItem(outline.item(atRow: 0))
        stage.drain()
        XCTAssertEqual(mark(row: 0), Activity.needsInput.label)
    }

    func testAMarkFollowsItsSessionAndGoesWhenTheSessionDoes() {
        outline.expandItem(outline.item(atRow: 0))
        activities.send([Self.url("A"): .responding])
        stage.drain()
        XCTAssertEqual(mark(row: 1), Activity.responding.label)
        activities.send([Self.url("A"): .needsInput])
        stage.drain()
        XCTAssertEqual(mark(row: 1), Activity.needsInput.label)
        activities.send([:])
        stage.drain()
        XCTAssertNil(mark(row: 1))
    }

    // MARK: - Menu

    private func menu(forRow row: Int) -> NSMenu? {
        let rect = outline.convert(outline.rect(ofRow: row), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
            timestamp: 0, windowNumber: stage.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1)
        guard let menu = event.flatMap({ outline.menu(for: $0) }) else { return nil }
        // What AppKit does as the menu opens, once the click has set `clickedRow`.
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    func testALiveSessionsMenuEndsIt() throws {
        outline.expandItem(outline.item(atRow: 0))
        activities.send([Self.url("B"): .responding])
        stage.drain()
        let reported = ReportingDelegate()
        sidebar.delegate = reported

        let menu = try XCTUnwrap(menu(forRow: 2))
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(menu.items.map(\.title), [String(localized: "End Session")])
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(reported.ended.map(\.title), ["B"])
    }

    func testARowAtRestAndAGroupHaveNoMenu() {
        outline.expandItem(outline.item(atRow: 0))
        activities.send([Self.url("B"): .idle])
        stage.drain()
        XCTAssertEqual(menu(forRow: 1)?.items.count, 0)
        XCTAssertEqual(menu(forRow: 0)?.items.count, 0)
    }
}

private final class ReportingDelegate: SidebarViewControllerDelegate {
    var ended: [LibraryNode] = []
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: LibraryNode) {}
    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode) {}
    func sidebarViewController(_ sidebar: SidebarViewController, didRequestEndOf node: LibraryNode) {
        ended.append(node)
    }
}

extension SessionState.Activity {
    fileprivate var label: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .responding: String(localized: "Responding")
        case .needsInput: String(localized: "Needs Your Input")
        case .failed: String(localized: "Failed")
        }
    }
}
