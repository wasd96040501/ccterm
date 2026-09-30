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
            [#selector(EditorAreaViewController.goBack(_:)), #selector(EditorAreaViewController.goForward(_:))])
        XCTAssertTrue(navigation.subitems.allSatisfy { $0.target === stage.mainSplit?.editorArea })
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
        try LibraryStoreTests.writeLibrary(fixture)
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

        split.editorArea.goBack(nil)
        XCTAssertEqual(tabTitles(of: split), ["Named"])
        split.editorArea.goForward(nil)
        XCTAssertEqual(tabTitles(of: split), ["fix it"])
    }

    // MARK: - Title

    /// The title is the active transcript's project — its folder in the
    /// sidebar — under its session's branch; it follows the reader from tab to
    /// tab and goes, at once, with the last.
    func testTheTitleIsTheActiveTranscriptsProjectAndBranch() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        // "Named" ran on a branch in a folder that is no repository here, so the
        // branch is the one its transcript recorded.
        try fixture.write(
            "-x-repo/s1.jsonl", [Self.user(cwd: "/x/repo", branch: "feature"), Rows.customTitle("Named")],
            modified: 300)
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
        await expect(title, shows: "repo", "feature")
        XCTAssertFalse(title.isHidden)
        XCTAssertEqual(stage.window.title, "repo", "the Window menu names the window something else")

        sidebar.delegate?.sidebarViewController(sidebar, didOpen: try Self.node("fix it", in: library))
        await expect(title, shows: "other", nil)

        split.editorArea.closeTab(nil)
        await expect(title, shows: "repo", "feature")
        split.editorArea.closeTab(nil)
        XCTAssertTrue(title.isHidden, "the title outlived the last tab")
        XCTAssertEqual(stage.window.title, "ccterm")
    }

    /// A document belongs to its transcript's session, so while it is the
    /// active tab the title keeps that transcript's project — Xcode keeps the
    /// project when the assistant editor has focus.
    func testADocumentKeepsItsTranscriptsTitle() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        try fixture.write(
            "-x-repo/s1.jsonl", [Self.user(cwd: "/x/repo", branch: "feature"), Rows.customTitle("Named")],
            modified: 300)
        let library = try await Self.startedLibrary(fixture)
        defer { library.stop() }
        let stage = AppKitStage.mainWindow(library: library)
        defer { stage.teardown() }
        await stage.settle()
        let split = try XCTUnwrap(stage.mainSplit)
        let sidebar = try sidebar(of: split)
        let title = try titleView(in: stage)
        sidebar.delegate?.sidebarViewController(sidebar, didOpen: try Self.node("Named", in: library))
        await expect(title, shows: "repo", "feature")
        let transcript = try XCTUnwrap(split.editorArea.activeViewController as? TranscriptViewController)

        let document = Document(
            reference: DocumentReference(transcriptURL: transcript.fileURL, id: "c1"),
            content: .compactionSummary("Summary"), workingDirectory: nil)
        split.transcriptViewController(transcript, open: document, pinned: false)
        await stage.settle()
        XCTAssertTrue(
            split.editorArea.activeViewController is DocumentViewController, "the document's editor is active")
        XCTAssertFalse(title.isHidden, "the title left with the transcript's editor")
        await expect(title, shows: "repo", "feature")
    }

    /// The CLI records a detached HEAD as "HEAD": no branch under the name.
    func testARecordedDetachedHeadShowsNoBranch() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        try fixture.write(
            "-x-repo/s1.jsonl", [Self.user(cwd: "/x/repo", branch: "HEAD"), Rows.customTitle("Named")],
            modified: 300)
        let library = try await Self.startedLibrary(fixture)
        defer { library.stop() }
        let stage = AppKitStage.mainWindow(library: library)
        defer { stage.teardown() }
        await stage.settle()
        let sidebar = try sidebar(of: try XCTUnwrap(stage.mainSplit))

        sidebar.delegate?.sidebarViewController(sidebar, didOpen: try Self.node("Named", in: library))
        await expect(try titleView(in: stage), shows: "repo", nil)
    }

    /// Alone, the name is centred; a branch coming raises it — moving, not
    /// jumping — and fades in under it, and one going does the reverse.
    func testTheNameRisesAsTheBranchFadesInUnderIt() async throws {
        let stage = AppKitStage.mainWindow()
        defer { stage.teardown() }
        await stage.settle()
        let title = try titleView(in: stage)
        let fields = stage.findAll(NSTextField.self, in: title)
        XCTAssertEqual(fields.count, 2, "premise: a name line and a branch line")
        let (nameLine, branchLine) = (fields[0], fields[1])
        let frame = { (view: NSView) in view.convert(view.bounds, to: nil) }
        title.title = "project"
        stage.window.layoutIfNeeded()
        XCTAssertEqual(frame(nameLine).midY, frame(title).midY, accuracy: 0.5, "the name alone is off centre")

        let rise = AnimationProbe.record(nameLine, frames: 40, timeout: 1) { title.subtitle = "main" }
        stage.window.layoutIfNeeded()
        let lines = frame(nameLine).union(frame(branchLine))
        XCTAssertEqual(lines.midY, frame(title).midY, accuracy: 0.5, "the two lines are off centre")
        XCTAssertEqual(frame(branchLine).maxY, frame(nameLine).minY, accuracy: 0.5, "the branch isn't under the name")
        XCTAssertEqual(branchLine.alphaValue, 1)

        let fadeOut = AnimationProbe.record(branchLine, frames: 40, timeout: 1) { title.subtitle = nil }
        stage.window.layoutIfNeeded()
        XCTAssertEqual(frame(nameLine).midY, frame(title).midY, accuracy: 0.5, "the name didn't return to centre")

        let fadeIn = AnimationProbe.record(branchLine, frames: 40, timeout: 1) { title.subtitle = "main" }

        fadeOut.assertOpacity(from: 1, to: 0)
        fadeIn.assertOpacity(from: 0, to: 1)
        // Under Reduce Motion the change is meant to land at once: only where it
        // lands is asserted, above.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rise.assertNoJump(.originY, maxStep: 2)
            XCTAssertGreaterThan(
                Set(rise.composited.compactMap { $0.presentationFrame?.minY }).count, 3,
                "the name jumped up\n\(rise.report())")
            XCTAssertTrue(
                fadeIn.composited.contains { ($0.opacity ?? 0) > 0.05 && ($0.opacity ?? 1) < 0.95 },
                "the branch popped in\n\(fadeIn.report())")
        }
        add(XCTAttachment(string: rise.report()))
        add(XCTAttachment(string: fadeIn.report()))
    }

    // MARK: - Fixtures

    typealias Rows = SessionDirectoryFixture

    /// A prompt from a session run in `cwd` on `branch`, as the CLI records it.
    private static func user(cwd: String, branch: String) -> String {
        Rows.row([
            "type": "user", "uuid": "u", "parentUuid": NSNull(), "sessionId": "s", "cwd": cwd, "gitBranch": branch,
            "message": ["role": "user", "content": "hi"],
        ])
    }

    // MARK: - Showing

    /// The window waits for the library's first read, and opens on its tree.
    func testTheWindowOpensOnceTheLibraryIsRead() async throws {
        let fixture = try SessionDirectoryFixture()
        defer { fixture.remove() }
        try LibraryStoreTests.writeLibrary(fixture)
        let library = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
        let controller = Self.parked(MainWindowController(library: library, git: GitService()))
        let window = try XCTUnwrap(controller.window)
        defer {
            window.orderOut(nil)
            library.stop()
        }

        controller.showWindow(whenLoadedWithin: .seconds(60))
        XCTAssertFalse(window.isVisible, "shown before the library was read")
        library.start()
        await fulfillment(of: [Self.visible(window)], timeout: 10)

        let sidebar = try sidebar(of: try XCTUnwrap(controller.contentViewController as? MainSplitViewController))
        XCTAssertEqual(Self.find(NSOutlineView.self, in: sidebar.view)?.numberOfRows, 2)
        XCTAssertEqual(Self.find(NSProgressIndicator.self, in: sidebar.view)?.superview?.isHidden, true)
    }

    /// A library that takes too long: the window opens anyway, the sidebar
    /// saying it is loading.
    func testTheWindowOpensAtTheDeadlineWhileTheLibraryLoads() async throws {
        let library = LibraryStore(directories: Empty().eraseToAnyPublisher())
        let controller = Self.parked(MainWindowController(library: library, git: GitService()))
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }

        controller.showWindow(whenLoadedWithin: .milliseconds(100))
        XCTAssertFalse(window.isVisible)
        await fulfillment(of: [Self.visible(window)], timeout: 10)

        let sidebar = try sidebar(of: try XCTUnwrap(controller.contentViewController as? MainSplitViewController))
        XCTAssertEqual(Self.find(NSOutlineView.self, in: sidebar.view)?.numberOfRows, 0)
        XCTAssertEqual(Self.find(NSProgressIndicator.self, in: sidebar.view)?.superview?.isHidden, false)
    }

    /// `controller`'s window where the harness parks one — off-screen, almost
    /// transparent — but not yet shown.
    private static func parked(_ controller: MainWindowController) -> MainWindowController {
        let window = controller.window!
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        return controller
    }

    private static func visible(_ window: NSWindow) -> XCTestExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.isVisible }, object: nil)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private static func session(_ name: String) -> LibraryNode {
        let url = URL(fileURLWithPath: "/nonexistent/\(name).jsonl")
        return LibraryNode(id: url.path, kind: .session, title: name, transcriptURL: url, children: [])
    }

    /// A library over `fixture`, read.
    private static func startedLibrary(_ fixture: SessionDirectoryFixture) async throws -> LibraryStore {
        let library = LibraryStore(directories: Just(fixture.directory).eraseToAnyPublisher())
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

    /// Returns once the title view names `project` over `branch`, which the
    /// window controller sets from a task on the main actor — so this awaits,
    /// yielding it.
    private func expect(_ view: MainWindowTitleView, shows project: String, _ branch: String?) async {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { view.title == project && view.subtitle == branch }
            }, object: nil)
        _ = await XCTWaiter().fulfillment(of: [shown], timeout: 5)
        XCTAssertEqual(view.title, project, "the name")
        XCTAssertEqual(view.subtitle, branch, "the branch under \(project)")
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
