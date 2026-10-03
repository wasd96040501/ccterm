import AppKit
import Components
import XCTest

@testable import ccterm

/// A worktree session's row carries a branch glyph after its title in
/// tertiary (design 08 *The sidebar*) — beside rows without one, with a mark,
/// selected, and with a title too long to fit. Review only —
/// `make test-unit FILTER=SidebarWorktreeSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/SidebarWorktree-Light.png` and `-Dark.png`.
@MainActor
final class SidebarWorktreeSnapshotTests: XCTestCase {
    private func session(_ title: String, worktree: String?) -> LibraryNode {
        let url = URL(fileURLWithPath: "/x/\(title).jsonl")
        return LibraryNode(
            id: url.path, kind: .session, title: title, transcriptURL: url, children: [], worktreeBranch: worktree)
    }

    private func mount(_ appearance: NSAppearance.Name) throws -> (SidebarViewController, NSOutlineView) {
        let children = [
            session("Fix the gutter", worktree: nil),
            session("Rework the sidebar", worktree: "worktree-quiet-otter"),
            session("Review pull request 327", worktree: "pr-327"),
            session("A worktree session whose title is far too long to fit the row", worktree: "worktree-long-name"),
        ]
        let nodes = [LibraryNode(id: "/x", kind: .project, title: "repo", transcriptURL: nil, children: children)]
        let activities: [URL: SessionState.Activity] = [children[1].transcriptURL!: .responding]
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.show(nodes.map(SidebarNode.init))
        sidebar.show(activities.mapValues(SidebarActivity.init))
        sidebar.view.appearance = NSAppearance(named: appearance)
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: sidebar.view))
        outline.expandItem(outline.item(atRow: 0))
        return (sidebar, outline)
    }

    private func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let found = view as? V { return found }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }

    private func render(_ appearance: NSAppearance.Name, name: String) throws {
        let (sidebar, outline) = try mount(appearance)
        outline.selectRowIndexes([3], byExtendingSelection: false)
        let image = ViewSnapshot.renderViewController(sidebar, size: CGSize(width: 260, height: 22 * 6), settle: 0.5) {
            outline.window?.makeFirstResponder(outline)
            sidebar.view.displayIfNeeded()
        }
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLight() throws { try render(.aqua, name: "SidebarWorktree-Light") }
    func testDark() throws { try render(.darkAqua, name: "SidebarWorktree-Dark") }
}
