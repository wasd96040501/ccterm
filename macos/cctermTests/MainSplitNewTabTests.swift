import AgentSDK
import AppKit
import Combine
import Components
import TranscriptWorkspace
import XCTest

@testable import ccterm

/// The window around New tabs (design 08 *Tabs and the +*): an area with no tab
/// that is a New view, ⌘T and the +, what a New tab starts with, and what Send
/// does to the tab and the window. The store only reads here, so a started
/// session is a URL and nothing launches.
@MainActor
final class MainSplitNewTabTests: XCTestCase {
    private var stage: AppKitStage!
    private var split: MainSplitViewController!
    private var area: EditorAreaViewController!
    private let window = WindowRecorder()
    private let recent = [URL(fileURLWithPath: "/tmp/newest"), URL(fileURLWithPath: "/tmp/older")]
    private var suite: String!

    override func setUp() async throws {
        continueAfterFailure = false
        suite = "ccterm-tests-\(UUID().uuidString)"
        let context = TranscriptTab.Context(
            sessions: .reading(), catalog: Just(ModelCatalog()).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: suite)!), branches: BranchService(),
            recentFolders: Just(recent).eraseToAnyPublisher())
        let library = LibraryStore(
            directories: Just(
                SessionDirectory(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            ).eraseToAnyPublisher())
        stage = AppKitStage.mount(MainSplitViewController(library: library, context: context))
        await stage.settle()
        split = try XCTUnwrap(stage.mainSplit)
        split.delegate = window
        area = try XCTUnwrap(split.splitViewItems[1].viewController as? EditorAreaViewController)
    }

    override func tearDown() async throws {
        stage.teardown()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func composer(of tab: NSViewController) throws -> ComposerViewController {
        try XCTUnwrap(tab.children.compactMap { $0 as? ComposerViewController }.first)
    }

    private func tab(at index: Int, in group: EditorGroupViewController? = nil) throws -> SessionTabViewController {
        try XCTUnwrap((group ?? area.activeGroup).tabViewItems[index].viewController as? SessionTabViewController)
    }

    private func send(_ text: String, in tab: SessionTabViewController) throws {
        let composer = try composer(of: tab)
        composer.text = ""
        tab.composerViewController(composer, didSubmit: text)
    }

    /// The active editor's bar, which the package keeps to itself.
    private var tabBar: NSView {
        stage.findAll(NSView.self, in: area.activeGroup.view).first {
            String(describing: type(of: $0)) == "EditorTabBar"
        }
            ?? NSView()
    }

    private var identifiers: [TranscriptTab?] {
        area.activeGroup.tabViewItems.map { TranscriptTab(identifier: $0.identifier) }
    }

    // MARK: - No tabs

    func testWithNoTabsTheAreaIsANewViewWithNoBarAndNoPlus() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController, "the area has no New view")
        stage.drain(seconds: 0.1)

        XCTAssertTrue(area.activeGroup.tabViewItems.isEmpty)
        XCTAssertIdentical(empty.parent, area.activeGroup, "the New view is not in the editor")
        XCTAssertTrue(tabBar.isHidden, "no tabs, no bar")
        XCTAssertTrue(area.showsNewTabButton)
        XCTAssertTrue(empty.isUntouchedDraft)
    }

    func testTheEmptyAreaStartsInTheMostRecentProject() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)

        XCTAssertEqual(empty.folder, recent[0])
    }

    /// The New view is already there: ⌘T has nothing to add.
    func testNewTabWithNoTabsAddsNone() {
        area.newTab(nil)

        XCTAssertTrue(area.activeGroup.tabViewItems.isEmpty)
    }

    /// Sending from the area opens the session as the first tab — the same
    /// controller, moved into it — and the window follows.
    func testSendingFromTheEmptyAreaMakesThatControllerTheFirstTab() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)

        try send("Fix the gutter", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })

        XCTAssertEqual(area.activeGroup.tabViewItems.count, 1)
        let item = area.activeGroup.tabViewItems[0]
        XCTAssertIdentical(item.viewController, empty, "the New view was replaced rather than moved")
        guard case .transcript(let url)? = TranscriptTab(identifier: item.identifier) else {
            return XCTFail("the tab is not its session's: \(String(describing: item.identifier))")
        }
        XCTAssertEqual(empty.transcriptURL, url)
        XCTAssertIdentical(area.activeViewController, empty)
        XCTAssertFalse(tabBar.isHidden, "the bar did not appear with the first tab")
        XCTAssertEqual(item.label, "Fix the gutter", "the tab is not named for the prompt")
        XCTAssertEqual(window.shown, [url], "the window was not told once")
    }

    /// The area has a New view again for the next time the tabs run out.
    func testTheAreaGetsANewViewAgainAfterTheFirstTab() throws {
        let first = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)

        try send("Fix the gutter", in: first)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })

        let next = try XCTUnwrap(area.emptyViewController as? SessionTabViewController, "no New view for later")
        XCTAssertNotIdentical(next, first)
        XCTAssertTrue(next.isUntouchedDraft)
        XCTAssertNil(next.parent, "the New view for later is showing under a tab")
    }

    /// The last tab closing leaves the area a New view — with the words of the
    /// New tab that closed.
    func testClosingTheLastTabShowsANewViewWithItsWords() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("Fix the gutter", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        let draft = try tab(at: 1)
        try composer(of: draft).text = "half a thought"

        area.closeTab(nil)  // the New tab
        area.closeTab(nil)  // the session's
        stage.drain(seconds: 0.1)

        let showing = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        XCTAssertTrue(area.activeGroup.tabViewItems.isEmpty)
        XCTAssertIdentical(showing.parent, area.activeGroup, "the New view is not showing")
        XCTAssertEqual(try composer(of: showing).text, "half a thought")
        XCTAssertFalse(window.shown.isEmpty)
        XCTAssertNil(window.shown.last!, "the window still shows the closed session")
    }

    // MARK: - New tabs

    func testNewTabOpensAfterTheActiveOneAndSelectsIt() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.activeGroup.addTabViewItem(NSTabViewItem(viewController: NSViewController()))
        area.activeGroup.selectedTabViewItemIndex = 0

        area.newTab(nil)

        XCTAssertEqual(area.activeGroup.tabViewItems.count, 3)
        XCTAssertEqual(area.activeGroup.selectedTabViewItemIndex, 1, "a New tab goes after the active one")
        guard case .newSession? = identifiers[1] else { return XCTFail("not a New tab: \(identifiers)") }
        XCTAssertEqual(area.activeGroup.tabViewItems[1].label, SessionTabTitle.draft)
        XCTAssertNil(area.activeGroup.previewTabViewItem, "a New tab is pinned")
    }

    /// An empty draft is not worth two tabs.
    func testNewTabSelectsTheGroupsUntouchedNewTabInsteadOfAddingAnother() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        XCTAssertEqual(area.activeGroup.tabViewItems.count, 2, "premise: the first New tab was added")
        area.activeGroup.selectedTabViewItemIndex = 0

        area.newTab(nil)

        XCTAssertEqual(area.activeGroup.tabViewItems.count, 2, "a second New tab was added")
        XCTAssertEqual(area.activeGroup.selectedTabViewItemIndex, 1)
    }

    func testNewTabAddsAnotherOnceTheFirstHasWordsInIt() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        try composer(of: try tab(at: 1)).text = "typed"

        area.newTab(nil)

        XCTAssertEqual(area.activeGroup.tabViewItems.count, 3)
    }

    /// Its words are kept, and the next New tab in the window opens with them.
    func testTheWordsOfAClosedNewTabOpenTheNextOne() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        try composer(of: try tab(at: 1)).text = "Don't lose this"
        area.closeTab(nil)
        XCTAssertEqual(area.activeGroup.tabViewItems.count, 1, "premise: the New tab closed")

        area.newTab(nil)

        let next = try tab(at: 1)
        XCTAssertEqual(try composer(of: next).text, "Don't lose this")
        XCTAssertFalse(next.isUntouchedDraft)

        // Once, not for every New tab after it.
        area.activeGroup.selectedTabViewItemIndex = 0
        try composer(of: next).text = "more"
        area.newTab(nil)
        XCTAssertEqual(try composer(of: try tab(at: 1)).text, "", "inserted after the active tab")
    }

    /// From a New tab the reader chose a folder in, the next starts in it.
    func testANewTabStartsInTheActiveNewTabsFolder() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        let draft = try tab(at: 1)
        XCTAssertEqual(draft.folder, recent[0], "premise: the most recent project when no session says otherwise")
        let chosen = URL(fileURLWithPath: "/tmp/chosen")
        let newSession = try XCTUnwrap(draft.children.compactMap { $0 as? NewSessionViewController }.first)
        draft.newSessionViewController(newSession, didChooseFolder: chosen)

        area.newTab(nil)

        XCTAssertEqual(try tab(at: 2).folder, chosen)
    }

    // MARK: - A New tab becomes its session's

    func testSendingFromANewTabReidentifiesTheItemInPlace() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })
        area.newTab(nil)
        let draft = try tab(at: 1)
        let item = area.activeGroup.tabViewItems[1]
        let identifier = try XCTUnwrap(item.identifier as? TranscriptTab)

        try send("Second prompt", in: draft)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { draft.transcriptURL != nil })

        XCTAssertIdentical(area.activeGroup.tabViewItems[1], item, "the item was replaced")
        guard case .transcript(let url)? = TranscriptTab(identifier: item.identifier) else {
            return XCTFail("still \(identifier)")
        }
        XCTAssertEqual(draft.transcriptURL, url)
        XCTAssertTrue(
            area.selectTabViewItem(withIdentifier: TranscriptTab.transcript(url)), "lookup by the new identifier")
        XCTAssertNil(area.tabViewItem(withIdentifier: identifier), "the old identifier still finds the tab")
        XCTAssertEqual(window.shown.last!, url, "the window was not told of the new session")
        XCTAssertEqual(item.label, "Second prompt")
    }

    /// A launch stopped before it began: the New tab again — its history gone,
    /// the window showing no session.
    func testReturningToTheDraftMakesTheItemANewTabAgain() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })

        split.transcriptTabDidReturnToDraft(empty)

        guard case .newSession? = identifiers[0] else { return XCTFail("not a New tab: \(identifiers)") }
        XCTAssertNil(window.shown.last!)
    }

    // MARK: - Commands

    /// ⌘T reaches the area from the sidebar too, where focus never is a tab.
    func testNewTabIsAnAreaCommandTheSplitHandsOnFromTheSidebar() throws {
        let target = split.supplementalTarget(forAction: #selector(EditorAreaViewController.newTab(_:)), sender: nil)

        XCTAssertIdentical(target as AnyObject?, area)
    }

    /// ⌘. stops the session in the active tab, from wherever the focus is.
    func testStopIsHandedToTheActiveSessionTab() throws {
        let empty = try XCTUnwrap(area.emptyViewController as? SessionTabViewController)
        try send("First", in: empty)
        XCTAssertTrue(stage.drainUntil(timeout: 5) { !self.area.activeGroup.tabViewItems.isEmpty })

        let target = split.supplementalTarget(
            forAction: #selector(SessionTabViewController.stopResponding(_:)), sender: nil)

        XCTAssertIdentical(target as AnyObject?, empty)
    }
}

/// What the window was told it is showing.
@MainActor
private final class WindowRecorder: MainSplitViewControllerDelegate {
    /// Each `didShowTranscriptAt`, in order.
    var shown: [URL?] = []

    func mainSplitViewController(_ split: MainSplitViewController, didShowTranscriptAt url: URL?) {
        shown.append(url)
    }
}
