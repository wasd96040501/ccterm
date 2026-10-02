import AgentSDK
import AppKit
import Combine
import TranscriptKit
import XCTest

@testable import ccterm

/// Renders the AppKit-rooted main window's content (the sidebar/detail
/// split) into an offscreen NSWindow, captures a PNG, and attaches it to
/// the xcresult. The sidebar reads a synthetic library with its first
/// project and session expanded, and one session is open in a tab.
///
/// Like the other snapshot tests in this target, the test is review-only —
/// no golden-image gate. `make test-unit` skips this class unless
/// explicitly filtered in
/// (`make test-unit FILTER=MainWindowAppKitSnapshotTests`).
@MainActor
final class MainWindowAppKitSnapshotTests: XCTestCase {
    typealias Rows = SessionDirectoryFixture

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMainSplitSnapshot() throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        var lines: [String] = []
        var parent: String?
        for turn in 0..<12 {
            lines.append(Rows.user("u\(turn)", parent: parent, "How does step \(turn) work?"))
            lines.append(
                Rows.assistant(
                    "a\(turn)", parent: "u\(turn)",
                    "Step \(turn) reads the **session directory** and builds the tree.\n\n- one\n- two"))
            parent = "a\(turn)"
        }
        lines.append(Rows.customTitle("Named"))
        try fixture.write("-x-repo/s1.jsonl", lines, modified: 300)

        let store = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
        let split = MainSplitViewController(library: store, sessions: .reading())
        split.loadViewIfNeeded()
        store.start()
        defer { store.stop() }
        // Synchronous throughout: `renderViewController` spins the run loop
        // inside this job, and an async test body would keep the tab's
        // main-actor load from resuming there.
        let deadline = Date(timeIntervalSinceNow: 10)
        while store.nodes.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let outline = try XCTUnwrap(Self.find(NSOutlineView.self, in: split.view))
        outline.expandItem(outline.item(atRow: 0))
        outline.expandItem(outline.item(atRow: 1))
        let session = try XCTUnwrap(store.nodes.first?.children.first)
        let sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
        split.sidebarViewController(sidebar, didOpen: session)

        let size = CGSize(width: 1200, height: 800)
        let image = ViewSnapshot.renderViewController(split, size: size, settle: 1.5)

        let url = ViewSnapshot.writePNG(image, name: "MainWindowAppKit-MainSplit")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MainWindowAppKit-MainSplit.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
        XCTAssertEqual(Self.find(TranscriptView.self, in: split.view)?.numberOfRows, 24)
    }

    /// The split before the library's first read: the sidebar's spinner and
    /// its line.
    func testLoadingSidebarSnapshot() throws {
        let store = LibraryStore(directories: Empty().eraseToAnyPublisher())
        let split = MainSplitViewController(library: store, sessions: .reading())
        let image = ViewSnapshot.renderViewController(split, size: CGSize(width: 1200, height: 800), settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "MainWindowAppKit-LoadingSidebar")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MainWindowAppKit-LoadingSidebar.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The whole window — titlebar, toolbar, tab bar under them — with two
    /// tabs open, the active one's session on a branch. Synchronous for the same
    /// reason as the split's: the branch arrives on a main-actor task. The
    /// sidebar comes out blank: its behind-window material is composited by
    /// the window server, which `cacheDisplay` doesn't reach — the split's
    /// snapshot shows its rows.
    func testMainWindowSnapshot() throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        let prompt = Rows.row([
            "type": "user", "uuid": "u", "parentUuid": NSNull(), "sessionId": "s", "cwd": "/x/repo",
            "gitBranch": "toolbar-pin-fixed-sidebar", "message": ["role": "user", "content": "hi"],
        ])
        try fixture.write("-x-repo/s1.jsonl", [prompt, Rows.customTitle("Named")], modified: 300)
        let store = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
        store.start()
        defer { store.stop() }
        let stage = AppKitStage.mainWindow(library: store)
        defer { stage.teardown() }
        XCTAssertTrue(stage.drainUntil(timeout: 10) { !store.nodes.isEmpty }, "the library never read")
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
        let sessions = store.nodes.flatMap(\.children)
        split.sidebarViewController(sidebar, didOpen: sessions[1])
        split.sidebarViewController(sidebar, didOpen: sessions[0])
        let title = try XCTUnwrap(stage.window.toolbar?.items.compactMap { $0.view as? MainWindowTitleView }.first)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { title.subtitle != nil }, "the branch never came")
        stage.drain(seconds: 0.5)

        let frameView = try XCTUnwrap(stage.window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)

        let url = ViewSnapshot.writePNG(image, name: "MainWindowAppKit-Window")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MainWindowAppKit-Window.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
