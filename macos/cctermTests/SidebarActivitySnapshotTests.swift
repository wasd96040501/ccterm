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

    // MARK: - Against the design

    /// The sheet's sidebar specimen (*The sidebar and the conversation icon*):
    /// a project open on four sessions — one working, one selected, one waiting
    /// for the reader — and a closed one, 240 pt wide, light (`side0`) and dark
    /// (`side1`). The selection is the unfocused one, grey, as the sheet draws it.
    func testTheSidebarAgainstTheDesign() throws {
        let titles = ["Smaller run-row summary", "Row gap and tool rows", "Review the diff", "Nightly build"]
        var activities: [URL: Activity] = [:]
        let sessions = titles.map { title -> LibraryNode in
            let url = URL(fileURLWithPath: "/dev/ccterm/\(title).jsonl")
            return LibraryNode(id: url.path, kind: .session, title: title, transcriptURL: url, children: [])
        }
        activities[sessions[0].transcriptURL!] = .responding
        activities[sessions[2].transcriptURL!] = .needsInput
        let ghosttyURL = URL(fileURLWithPath: "/dev/ghostty/s.jsonl")
        let nodes = [
            LibraryNode(id: "/dev/ccterm", kind: .project, title: "ccterm", transcriptURL: nil, children: sessions),
            LibraryNode(
                id: "/dev/ghostty", kind: .project, title: "ghostty", transcriptURL: nil,
                children: [
                    LibraryNode(
                        id: ghosttyURL.path, kind: .session, title: "Tab bar accessory", transcriptURL: ghosttyURL,
                        children: [])
                ]),
        ]
        for (id, appearance) in [("part-06-side0", NSAppearance.Name.aqua), ("part-06-side1", .darkAqua)] {
            let part = try DesignParity.part(id, .light)
            NSApp.appearance = NSAppearance(named: appearance)
            defer { NSApp.appearance = nil }
            let sidebar = SidebarViewController(
                nodes: Just(nodes).eraseToAnyPublisher(), activities: Just(activities).eraseToAnyPublisher())
            sidebar.loadViewIfNeeded()
            let window = CompositedCapture.mount(
                sidebar, size: NSSize(width: part.width, height: part.height),
                appearance: NSAppearance(named: appearance))
            defer { window.close() }
            let outline = try XCTUnwrap(Self.find(NSOutlineView.self, in: sidebar.view))
            outline.expandItem(outline.item(atRow: 0))
            outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            window.makeFirstResponder(nil)
            // Composited, so the source list's selection and its images are as on screen.
            var captured: Result<NSImage, Error>?
            let done = expectation(description: "captured")
            Task {
                do { captured = .success(try await CompositedCapture.pointImage(of: window)) } catch {
                    captured = .failure(error)
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 120)
            let image = try XCTUnwrap(captured).get()
            let url = try DesignParity.write(id, .light, ours: image)
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEveryMarkInLight() throws { try render(.aqua, name: "SidebarActivity-Light") }

    func testEveryMarkInDark() throws { try render(.darkAqua, name: "SidebarActivity-Dark") }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
