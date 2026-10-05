import AgentSDK
import AppKit
import Combine
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// A session tab as a container: what a New tab is made of and the words it
/// opens with, how it is told apart from one the reader has touched, what a
/// session tab is called and what its restart sheet and its documents beside
/// say. The Send handover and the window around it are `SessionTabHandoverTests`.
@MainActor
final class SessionTabViewControllerTests: XCTestCase {
    private var stage: AppKitStage?
    private var defaultsSuite: String!

    override func setUp() async throws {
        continueAfterFailure = false
        defaultsSuite = "ccterm-tests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        stage?.teardown()
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
    }

    private func context(recent: [URL] = [], catalog: ModelCatalog = ModelCatalog()) -> TranscriptTab.Context {
        TranscriptTab.Context(
            sessions: .reading(), catalog: Just(catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: defaultsSuite)!),
            branches: BranchService(), recentFolders: Just(recent).eraseToAnyPublisher())
    }

    private func mountDraft(
        folder: URL? = URL(fileURLWithPath: "/tmp/repo"), text: String = "",
        context: TranscriptTab.Context? = nil, size: CGSize = CGSize(width: 900, height: 700)
    ) -> SessionTabViewController {
        let tab = SessionTabViewController(
            .draft(folder: folder, text: text), title: "New Session", context: context ?? self.context())
        stage = AppKitStage.mount(tab, size: size)
        tab.viewDidAppear()
        stage!.drain()
        return tab
    }

    private func composer(of tab: SessionTabViewController) throws -> ComposerViewController {
        try XCTUnwrap(tab.children.compactMap { $0 as? ComposerViewController }.first)
    }

    private func newSession(of tab: SessionTabViewController) -> NewSessionViewController? {
        tab.children.compactMap { $0 as? NewSessionViewController }.first
    }

    // MARK: - A New tab

    /// The New view in the tab, the one composer in its guide, the guide as
    /// tall as the composer.
    func testANewTabPutsTheComposerInTheNewViewsSlot() throws {
        let tab = mountDraft()
        let newSession = try XCTUnwrap(newSession(of: tab), "a New tab shows the New view")
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()

        let guide = newSession.view.convert(newSession.composerGuide.frame, to: tab.view)
        let card = composer.view.frame
        XCTAssertGreaterThan(card.height, 20, "premise: the composer was laid out")
        XCTAssertEqual(card.minX, guide.minX, accuracy: 0.5)
        XCTAssertEqual(card.maxX, guide.maxX, accuracy: 0.5)
        XCTAssertEqual(card.maxY, guide.maxY, accuracy: 0.5, "the composer is not at the top of its slot")
        XCTAssertEqual(guide.height, card.height, accuracy: 0.5, "the slot did not take the composer's height")
        XCTAssertLessThanOrEqual(card.width, 640.5, "the New view's composer is 640 pt at most")
        XCTAssertNil(tab.children.first { $0 is TranscriptViewController }, "a New tab has no transcript")
    }

    func testANewTabOpensWithTheWordsCarriedToIt() throws {
        let tab = mountDraft(text: "Fix the gutter")

        XCTAssertEqual(try composer(of: tab).text, "Fix the gutter")
        XCTAssertEqual(tab.draftText, "Fix the gutter")
        XCTAssertFalse(tab.isUntouchedDraft, "a New tab with words in it is worth keeping")
    }

    func testANewTabNobodyTouchedIsUntouchedUntilTheyType() throws {
        let tab = mountDraft()
        XCTAssertTrue(tab.isUntouchedDraft)
        XCTAssertEqual(tab.draftText, "")

        try composer(of: tab).text = "x"

        XCTAssertFalse(tab.isUntouchedDraft)
        XCTAssertEqual(tab.draftText, "x")
    }

    /// Choosing a folder is a choice: the tab is worth keeping.
    func testChoosingAFolderMakesTheTabTouched() throws {
        let tab = mountDraft()
        let newSession = try XCTUnwrap(newSession(of: tab))

        tab.newSessionViewController(newSession, didChooseFolder: URL(fileURLWithPath: "/tmp/other"))

        XCTAssertFalse(tab.isUntouchedDraft)
        XCTAssertEqual(tab.folder, URL(fileURLWithPath: "/tmp/other"))
    }

    /// The branch menu is the tab's to word: none for a folder that is no
    /// repository, and a branch item that is no branch changes nothing.
    func testTheBranchMenuNeedsARepository() throws {
        let tab = mountDraft()
        let newSession = try XCTUnwrap(newSession(of: tab))

        XCTAssertNil(tab.newSessionViewController(newSession, branchMenuMatching: ""))
        tab.newSessionViewController(newSession, didChooseBranchItem: "not a branch")

        XCTAssertTrue(tab.isUntouchedDraft)
    }

    func testANewTabStartsInTheFolderItIsGiven() {
        XCTAssertEqual(
            mountDraft(folder: URL(fileURLWithPath: "/tmp/given")).folder, URL(fileURLWithPath: "/tmp/given"))
    }

    /// With no folder known the tab takes the most recent project once the
    /// sidebar has one — and leaves it alone after the reader chose.
    func testANewTabWithNoFolderTakesTheMostRecentProject() {
        let recent = [URL(fileURLWithPath: "/tmp/newest"), URL(fileURLWithPath: "/tmp/older")]

        let tab = mountDraft(folder: nil, context: context(recent: recent))

        XCTAssertEqual(tab.folder, recent[0])
    }

    /// A session's tab has no draft: no words to keep, nothing to reuse.
    /// *Choose Folder…* (⌘O, a nil-targeted `chooseFolder:`) reaches the New
    /// view from the composer's focus, the composer being its sibling.
    func testChooseFolderReachesTheNewViewFromTheComposer() throws {
        let tab = mountDraft()
        let action = Selector(("chooseFolder:"))
        XCTAssertTrue(tab.supplementalTarget(forAction: action, sender: nil) as? NSObject === newSession(of: tab))

        let session = SessionTabViewController(
            .session(URL(fileURLWithPath: "/nonexistent/s.jsonl")), title: "s", context: context())
        XCTAssertNil(session.supplementalTarget(forAction: action, sender: nil))
    }

    /// File › Stop is greyed while there is nothing to stop.
    func testStopIsDisabledWithNothingToStop() {
        let tab = SessionTabViewController(
            .session(URL(fileURLWithPath: "/nonexistent/s.jsonl")), title: "s", context: context())
        let stop = NSMenuItem(title: "Stop", action: TranscriptTab.stopAction, keyEquivalent: ".")
        XCTAssertFalse(tab.validateMenuItem(stop))
    }

    func testASessionsTabIsNoDraft() throws {
        let tab = SessionTabViewController(
            .session(URL(fileURLWithPath: "/nonexistent/s.jsonl")), title: "s", context: context())
        stage = AppKitStage.mount(tab)

        XCTAssertNil(tab.draftText)
        XCTAssertFalse(tab.isUntouchedDraft)
        XCTAssertNil(tab.folder)
        XCTAssertNil(newSession(of: tab))
        XCTAssertNotNil(tab.children.first { $0 is TranscriptViewController })
    }

    // MARK: - Choices

    /// A choice in a New tab is saved as it is made, so the next New tab starts
    /// on it (design 08 *Defaults*).
    func testAChoiceInANewTabIsSavedAsTheNextOnesDefault() throws {
        let account = UUID()
        let catalog = ModelCatalog(accounts: [
            AccountCatalog(
                id: account, name: "Claude", detail: "Subscription", isSubscription: true, isLoaded: true,
                models: [InitializationResult.Model(value: "default", supportsAutoMode: true)],
                commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: .default)
        ])
        let context = context(catalog: catalog)
        let tab = mountDraft(context: context)

        tab.composerViewController(try composer(of: tab), didChoose: ComposerModel.id(of: .permissionMode(.plan)))

        XCTAssertEqual(context.defaults.settings(catalog: catalog)?.permissionMode, .plan)
    }

    // MARK: - What a tab is called

    func testAPromptsFirstLineIsTheTitle() {
        XCTAssertEqual(SessionTabTitle.fromPrompt("Fix the gutter\nand the margin"), "Fix the gutter")
        XCTAssertEqual(
            SessionTabTitle.fromPrompt("\n  \n  Tidy up  \nnext"), "Tidy up", "leading blank lines are skipped")
    }

    func testALongFirstLineIsCutAtFortyCharacters() {
        let long = String(repeating: "abcdefghij", count: 6)
        let title = SessionTabTitle.fromPrompt(long)
        XCTAssertEqual(title, String(long.prefix(40)) + "…")
        XCTAssertEqual(
            SessionTabTitle.fromPrompt(String(long.prefix(40))), String(long.prefix(40)), "exactly 40 is not cut")
    }

    func testWordsWithNoLineInThemAreStillANewSession() {
        XCTAssertEqual(SessionTabTitle.fromPrompt(""), SessionTabTitle.draft)
        XCTAssertEqual(SessionTabTitle.fromPrompt(" \n "), SessionTabTitle.draft)
        XCTAssertEqual(SessionTabTitle.draft, String(localized: "New Session"))
    }

    /// The CLI's name wins over the prompt's line, which wins over what the tab
    /// was opened with.
    func testTheCLIsNameWinsOverThePromptsLine() {
        XCTAssertEqual(
            SessionTabTitle.resolved(cli: "Gutter fix", prompt: "Fix the gutter", fallback: "x"), "Gutter fix")
        XCTAssertEqual(SessionTabTitle.resolved(cli: nil, prompt: "Fix the gutter", fallback: "x"), "Fix the gutter")
        XCTAssertEqual(SessionTabTitle.resolved(cli: "", prompt: "Fix the gutter", fallback: "x"), "Fix the gutter")
        XCTAssertEqual(
            SessionTabTitle.resolved(cli: nil, prompt: nil, fallback: "From the sidebar"), "From the sidebar")
        XCTAssertEqual(SessionTabTitle.resolved(cli: "Named", prompt: nil, fallback: "From the sidebar"), "Named")
    }

    func testAWorktreeSessionIsNamedByItsWorktreeNotTheCLIsBranch() {
        XCTAssertEqual(
            SessionTabTitle.worktreeSubtitle(branch: "worktree-quiet-otter"),
            String(localized: "\("quiet-otter") · worktree"))
        XCTAssertEqual(
            SessionTabTitle.worktreeSubtitle(branch: "pr-327"), String(localized: "\("pr-327") · worktree"))
        XCTAssertEqual(
            SessionTabTitle.worktreeSubtitle(branch: "worktree-"), String(localized: "\("worktree-") · worktree"),
            "a branch that is only the prefix is kept")
    }

    // MARK: - The restart sheet

    func testTheRestartSheetNamesTheAccountAndTheModel() {
        let words = RestartConfirmation(accountName: "Work Relay", modelName: "Sonnet", isWorking: false)

        XCTAssertTrue(words.title.contains("Work Relay"))
        XCTAssertTrue(words.message.contains("Work Relay"))
        XCTAssertTrue(words.message.contains("Sonnet"))
        XCTAssertEqual(words.confirmTitle, String(localized: "Restart"))
        XCTAssertEqual(words.cancelTitle, String(localized: "Cancel"))
        XCTAssertFalse(words.confirmIsDestructive)
        XCTAssertFalse(words.message.hasSuffix(String(localized: "Claude stops what it’s doing now.")))
    }

    /// While Claude works the restart stops the turn: the words say so, and
    /// Return must not throw it away.
    func testWhileWorkingTheRestartSheetSaysSoAndItsButtonIsDestructive() {
        let words = RestartConfirmation(accountName: "Work Relay", modelName: "Sonnet", isWorking: true)

        XCTAssertTrue(words.message.hasSuffix(String(localized: "Claude stops what it’s doing now.")))
        XCTAssertEqual(words.confirmTitle, String(localized: "Stop and Restart"))
        XCTAssertTrue(words.confirmIsDestructive)
    }

    // MARK: - Documents beside

    func testTheLogOpensAsADocumentOfTheFailureWithNoWayBackToARow() throws {
        let url = URL(fileURLWithPath: "/nonexistent/s.jsonl")
        let failure = SessionFailure(message: "Exit code 1 · boom", log: "line one\nline two\n")

        let document = SessionTabDocuments.log(failure, transcriptURL: url)

        XCTAssertEqual(document.reference, DocumentReference(transcriptURL: url, id: "log"))
        XCTAssertEqual(document.content, .log(failure))
        XCTAssertFalse(document.isLive, "nothing in the transcript backs it, so it is never reloaded")
        XCTAssertNil(document.approval)
        XCTAssertFalse(DocumentHeader(document).showsTranscriptJump)
    }

    func testTheContextRingOpensWhatTheCLIReported() throws {
        let url = URL(fileURLWithPath: "/nonexistent/s.jsonl")
        let usage = ContextUsageFixture.sample

        let document = SessionTabDocuments.context(usage, transcriptURL: url)

        XCTAssertEqual(
            document.reference, DocumentReference(transcriptURL: url, id: "context-\(usage.totalTokens)"))
        XCTAssertEqual(document.content, .contextUsage(usage))
        XCTAssertFalse(DocumentHeader(document).showsTranscriptJump)
        var fuller = usage
        fuller.totalTokens += 1000
        XCTAssertNotEqual(
            SessionTabDocuments.context(fuller, transcriptURL: url).reference, document.reference,
            "a different reading opens a tab of its own")
    }

    /// The pre-resolved document is a tab as any other: built through the same
    /// door a transcript's click uses, titled by what it is.
    func testALogDocumentMakesATabBesideTheSession() throws {
        let url = URL(fileURLWithPath: "/nonexistent/s.jsonl")
        let document = SessionTabDocuments.log(SessionFailure(message: "boom", log: "x"), transcriptURL: url)
        let delegate = TabRecorder()

        let item = TranscriptTab.makeDocumentItem(document, sessions: .reading(), delegate: delegate)

        XCTAssertEqual(TranscriptTab(identifier: item.identifier), .document(document.reference))
        XCTAssertEqual(item.viewController?.title, String(localized: "Session Log"))
    }

    /// A command token with nothing after it is something typed: the tab is
    /// worth keeping.
    func testADraftHoldingOnlyACommandTokenIsNotUntouched() throws {
        let tab = mountDraft()
        XCTAssertTrue(tab.isUntouchedDraft)

        try composer(of: tab).text = "/review"

        XCTAssertEqual(try composer(of: tab).text, "/review")
        XCTAssertFalse(tab.isUntouchedDraft)
        XCTAssertEqual(tab.draftText, "/review", "the token is kept for the next New tab")
    }
}

/// What a tab asked of its window.
@MainActor
final class TabRecorder: TranscriptTabDelegate {
    var started: [URL] = []
    var returnedToDraft = 0
    var opened: [TranscriptTab] = []
    /// What the tab's children were at each `didStartSessionAt`.
    var childrenAtStart: [[String]] = []
    var onStart: ((NSViewController, URL) -> Void)?

    func transcriptTab(_ source: NSViewController, didStartSessionAt url: URL) {
        started.append(url)
        childrenAtStart.append(source.children.map { String(describing: type(of: $0)) })
        onStart?(source, url)
    }

    func transcriptTabDidReturnToDraft(_ source: NSViewController) {
        returnedToDraft += 1
    }

    func transcriptTab(
        _ source: NSViewController, didRequestOpen tab: TranscriptTab, pinned: Bool, makeItem: () -> NSTabViewItem
    ) {
        opened.append(tab)
    }

    func transcriptTab(_ source: NSViewController, didRequestReveal itemID: String, inTranscriptAt url: URL) {}
}
