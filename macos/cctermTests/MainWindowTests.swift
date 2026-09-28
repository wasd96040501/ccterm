import AgentSDK
import AppKit
import Combine
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// The real main window — its titlebar, toolbar and split — parked off-screen:
/// what the toolbar holds, where the editors' tab bar sits under it, back and
/// forward through the active editor, and the project and branch in the title.
@MainActor
final class MainWindowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Toolbar

    /// Over the editors, Xcode's order: back and forward as one navigational
    /// control, then the project. No sidebar button — the sidebar doesn't
    /// collapse.
    func testTheToolbarIsBackAndForwardThenTheProject() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let toolbar = try XCTUnwrap(stage.window.toolbar)

        XCTAssertEqual(
            toolbar.items.map(\.itemIdentifier),
            [
                .sidebarTrackingSeparator, .init("ccterm.main.navigation"), .init("ccterm.main.projectTitle"),
                .flexibleSpace,
            ])
        let navigation = try XCTUnwrap(toolbar.items[1] as? NSToolbarItemGroup)
        XCTAssertTrue(navigation.isNavigational)
        XCTAssertEqual(
            navigation.subitems.map(\.action),
            [#selector(MainSplitViewController.goBack(_:)), #selector(MainSplitViewController.goForward(_:))])
        XCTAssertTrue(navigation.subitems.allSatisfy { $0.target === stage.mainSplit })
        XCTAssertFalse(toolbar.items[2].isBordered, "the title sits in a bezel")
    }

    func testTheSidebarCannotCollapse() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = split.splitViewItems[0]

        XCTAssertFalse(sidebar.canCollapse)
        XCTAssertFalse(sidebar.canCollapseFromWindowResize)
        // What the split view asks while its divider is dragged.
        XCTAssertFalse(
            split.splitView(split.splitView, canCollapseSubview: split.splitView.arrangedSubviews[0]),
            "dragging the divider can collapse the sidebar")
        let toggle = NSMenuItem(
            title: "", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        XCTAssertFalse(split.validateUserInterfaceItem(toggle), "Toggle Sidebar is enabled")
    }

    // MARK: - Tabs under the toolbar

    /// The tab bar starts under the toolbar, and a press on it reaches it rather
    /// than the titlebar — which would move or zoom the window instead of
    /// picking the tab up.
    func testTheTabBarIsUnderTheToolbarWhereAPressReachesIt() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        split.sidebarViewController(try sidebar(of: split), didOpen: Self.session("a"))
        await stage.settle()

        let bar = try XCTUnwrap(tabBar(in: stage), "no tab bar with one tab open")
        let frame = bar.convert(bar.bounds, to: nil)
        XCTAssertGreaterThan(frame.height, 0, "premise: the bar was laid out")
        XCTAssertLessThanOrEqual(
            frame.maxY, stage.window.contentLayoutRect.maxY + Geometry.tolerance, "the tab bar is under the toolbar")
        let frameView = try XCTUnwrap(stage.window.contentView?.superview)
        let centre = frameView.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)
        XCTAssertIdentical(frameView.hitTest(centre), bar, "a press on a tab goes somewhere else")
    }

    // MARK: - Back and forward

    /// The toolbar asks the split, as it validates after every event: back once
    /// the active editor has shown something before, forward once it went back.
    func testBackAndForwardFollowTheActiveEditor() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        let (back, forward) = try navigation(in: stage)
        split.sidebarViewController(try sidebar(of: split), didOpen: Self.session("a"))
        split.sidebarViewController(try sidebar(of: split), didOpen: Self.session("b"))

        stage.window.toolbar?.validateVisibleItems()
        XCTAssertTrue(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)

        NSApp.sendAction(try XCTUnwrap(back.action), to: back.target, from: back)
        stage.window.toolbar?.validateVisibleItems()
        XCTAssertEqual(activeTitle(of: split), "a")
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(forward.isEnabled)

        NSApp.sendAction(try XCTUnwrap(forward.action), to: forward.target, from: forward)
        XCTAssertEqual(activeTitle(of: split), "b")
    }

    /// Back to a transcript the temporary tab replaced opens it again, from the
    /// library, where it was replaced.
    func testGoingBackReopensWhatTheTemporaryTabReplaced() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        let library = try await Self.startedLibrary(fixture)
        defer { library.stop() }
        let stage = AppKitStage.mainWindow(library: library)
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = try sidebar(of: split)

        sidebar.delegate?.sidebarViewController(sidebar, didSelect: try Self.node("Named", in: library))
        sidebar.delegate?.sidebarViewController(sidebar, didSelect: try Self.node("fix it", in: library))
        XCTAssertEqual(tabTitles(of: split), ["fix it"], "premise: the look was replaced")

        split.goBack(nil)
        XCTAssertEqual(tabTitles(of: split), ["Named"])
        split.goForward(nil)
        XCTAssertEqual(tabTitles(of: split), ["fix it"])
    }

    // MARK: - Title

    /// The title is the active transcript's project — its folder in the
    /// sidebar — and goes with the last tab.
    func testTheTitleIsTheActiveTranscriptsProject() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        let library = try await Self.startedLibrary(fixture)
        defer { library.stop() }
        let stage = AppKitStage.mainWindow(library: library)
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = try sidebar(of: split)
        let title = try titleView(in: stage)
        XCTAssertTrue(title.isHidden, "a title with nothing open")

        sidebar.delegate?.sidebarViewController(sidebar, didOpen: try Self.node("Named", in: library))
        XCTAssertEqual(title.title, "repo")
        XCTAssertFalse(title.isHidden)
        XCTAssertEqual(stage.window.title, "repo", "the Window menu names the window something else")

        sidebar.delegate?.sidebarViewController(sidebar, didOpen: try Self.node("fix it", in: library))
        XCTAssertEqual(title.title, "other")

        split.closeTab(nil)
        XCTAssertEqual(title.title, "repo", "closing a tab left the title on the one closed")
        split.closeTab(nil)
        XCTAssertTrue(title.isHidden)
        XCTAssertEqual(stage.window.title, "ccterm")
    }

    /// Under the project's name, its branch as it is now — read after the
    /// name, off the main thread — and again after each checkout.
    func testTheSubtitleIsTheProjectsBranchAsItChanges() async throws {
        let repo = try GitRepoFixture(name: "project")
        defer { repo.remove() }
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let controller = try XCTUnwrap(stage.windowController as? MainWindowController)
        let title = try titleView(in: stage)

        controller.mainSplitViewController(try XCTUnwrap(stage.mainSplit), didShowProjectAt: repo.url)
        XCTAssertEqual(title.title, "project")
        await subtitle(of: title, becomes: "main")
        try repo.git("checkout", "-q", "-b", "feature")
        await subtitle(of: title, becomes: "feature")
    }

    /// The branch fades in where it goes: its opacity only rises, and the name
    /// above it doesn't move — both lines are laid out before either arrives.
    func testTheBranchFadesInWithoutMovingTheTitle() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let title = try titleView(in: stage)
        let fields = stage.findAll(NSTextField.self, in: title)
        XCTAssertEqual(fields.count, 2, "premise: a title line and a subtitle line")
        let (titleLine, subtitleLine) = (fields[0], fields[1])
        title.title = "project"
        stage.window.layoutIfNeeded()
        let titleFrame = titleLine.convert(titleLine.bounds, to: nil)
        // Its line: where it starts and how tall, not how long the text is.
        let subtitleLineBox = { (frame: NSRect) in NSRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
        }
        let subtitleFrame = subtitleLineBox(subtitleLine.convert(subtitleLine.bounds, to: nil))

        let timeline = AnimationProbe.record(subtitleLine, frames: 30, timeout: 1) { title.subtitle = "main" }

        stage.window.layoutIfNeeded()
        XCTAssertEqual(titleLine.convert(titleLine.bounds, to: nil), titleFrame, "the name moved when the branch came")
        XCTAssertEqual(
            subtitleLineBox(subtitleLine.convert(subtitleLine.bounds, to: nil)), subtitleFrame, "the branch moved in")
        timeline.assertOpacity(from: 0, to: 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(
                timeline.composited.contains { ($0.opacity ?? 0) > 0.05 && ($0.opacity ?? 1) < 0.95 },
                "the branch popped in\n\(timeline.report())")
        }
        // Its origin, not its centre: the line widens to the text while still clear.
        timeline.assertNoJump(.originX, maxStep: 0.5)
        timeline.assertNoJump(.originY, maxStep: 0.5)
        add(XCTAttachment(string: timeline.report()))
    }

    // MARK: - Fixtures

    private static func session(_ name: String) -> LibraryNode {
        let url = URL(fileURLWithPath: "/nonexistent/\(name).jsonl")
        return LibraryNode(id: url.path, kind: .session, title: name, transcriptURL: url, children: [])
    }

    /// A library over `LibraryStoreTests`' fixture — "Named" in `/x/repo`,
    /// "fix it" in `/y/other` — read.
    private static func startedLibrary(_ fixture: SessionDirectoryFixture) async throws -> LibraryStore {
        try LibraryStoreTests.writeLibrary(fixture)
        let library = LibraryStore(directory: fixture.directory)
        library.start()
        let loaded = XCTestExpectation(description: "library read")
        let subscription = library.$nodes.first { !$0.isEmpty }.sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        let result = await XCTWaiter().fulfillment(of: [loaded], timeout: 10)
        XCTAssertEqual(result, .completed, "the library never read")
        return library
    }

    private static func node(_ title: String, in library: LibraryStore) throws -> LibraryNode {
        try XCTUnwrap(library.nodes.flatMap(\.children).first { $0.title == title }, "no session \(title)")
    }

    private func sidebar(of split: MainSplitViewController) throws -> SidebarViewController {
        try XCTUnwrap(split.splitViewItems[0].viewController as? SidebarViewController)
    }

    private func navigation(in stage: AppKitStage) throws -> (back: NSToolbarItem, forward: NSToolbarItem) {
        let group = try XCTUnwrap(stage.window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup }.first)
        return (group.subitems[0], group.subitems[1])
    }

    /// Returns once the title view's subtitle is `branch`, which the window
    /// controller sets from a task on the main actor — so this awaits, yielding it.
    private func subtitle(of title: MainWindowTitleView, becomes branch: String) async {
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { title.subtitle == branch } }, object: nil)
        await fulfillment(of: [arrived], timeout: 5)
    }

    private func titleView(in stage: AppKitStage) throws -> MainWindowTitleView {
        try XCTUnwrap(stage.window.toolbar?.items.compactMap { $0.view as? MainWindowTitleView }.first)
    }

    /// The editors' tab bar, found as VoiceOver finds it: the one tab group.
    private func tabBar(in stage: AppKitStage) -> NSView? {
        stage.findAll(NSView.self).first { $0.accessibilityRole() == .tabGroup }
    }

    private func editorArea(of split: MainSplitViewController) -> EditorAreaViewController? {
        split.splitViewItems[1].viewController as? EditorAreaViewController
    }

    private func activeTitle(of split: MainSplitViewController) -> String? {
        editorArea(of: split)?.activeViewController?.title
    }

    private func tabTitles(of split: MainSplitViewController) -> [String] {
        editorArea(of: split)?.groups.flatMap(\.tabViewItems).compactMap { $0.viewController?.title } ?? []
    }
}
