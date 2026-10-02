import AppKit
import Combine
import XCTest

@testable import ccterm

/// Every activity mark in the sidebar, unselected and selected, light and dark
/// (design/sidebar-icons "Status marks"). Review only —
/// `make test-unit FILTER=SidebarActivitySnapshotTests`, then open
/// `/tmp/ccterm-screenshots/SidebarActivity-Light.png` and `-Dark.png`.
@MainActor
final class SidebarActivitySnapshotTests: XCTestCase {
    private typealias Activity = SessionState.Activity

    private static let states: [(String, Activity?)] = [
        ("Idle", .idle), ("Responding", .responding), ("Needs input", .needsInput),
        ("Failed, with a long title that has to truncate", .failed(message: "")), ("At rest", nil),
    ]

    private func render(_ appearance: NSAppearance.Name, name: String) throws {
        var children: [LibraryNode] = []
        var activities: [URL: Activity] = [:]
        for selected in [false, true] {
            for (title, activity) in Self.states {
                let url = URL(fileURLWithPath: "/x/\(title)\(selected).jsonl")
                children.append(
                    LibraryNode(
                        id: url.path, kind: .session, title: selected ? title + " (selected)" : title,
                        transcriptURL: url, children: []))
                activities[url] = activity
            }
        }
        let otherURL = URL(fileURLWithPath: "/y/s.jsonl")
        let other = LibraryNode(
            id: otherURL.path, kind: .session, title: "Waiting", transcriptURL: otherURL, children: [])
        activities[otherURL] = .needsInput
        let nodes = [
            LibraryNode(id: "/x", kind: .project, title: "repo", transcriptURL: nil, children: children),
            LibraryNode(id: "/y", kind: .project, title: "other (collapsed)", transcriptURL: nil, children: [other]),
        ]
        let sidebar = SidebarViewController(
            nodes: Just(nodes).eraseToAnyPublisher(), activities: Just(activities).eraseToAnyPublisher())
        sidebar.loadViewIfNeeded()
        sidebar.view.appearance = NSAppearance(named: appearance)
        let outline = try XCTUnwrap(Self.find(NSOutlineView.self, in: sidebar.view))
        outline.allowsMultipleSelection = true
        outline.expandItem(outline.item(atRow: 0))
        outline.selectRowIndexes(
            IndexSet(integersIn: (Self.states.count + 1)...(2 * Self.states.count)), byExtendingSelection: false)

        let size = CGSize(width: 260, height: 22 * 14 + 16)
        let image = ViewSnapshot.renderViewController(sidebar, size: size, settle: 0.5) {
            // The selection is emphasized only while the outline is the first responder.
            outline.window?.makeFirstResponder(outline)
            sidebar.view.displayIfNeeded()
        }
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size, size)
    }

    func testEveryMarkInLight() throws { try render(.aqua, name: "SidebarActivity-Light") }

    func testEveryMarkInDark() throws { try render(.darkAqua, name: "SidebarActivity-Dark") }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
