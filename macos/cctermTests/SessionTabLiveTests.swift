import AgentSDK
import AppKit
import Combine
import Components
import TranscriptKit
import XCTest

@testable import ccterm

/// Send in a New tab end to end: the tab over a store whose sessions launch
/// AgentSDK's scripted stand-in CLI (`fake_cli.py`; the prompt picks the
/// scenario). The tab becomes the session's in place, shows the held prompt
/// while the CLI starts, and Stop while *Starting* gives the words back to the
/// New tab. `SessionTabHandoverTests` covers the order and the motion over a
/// store that only reads; `SessionStoreTests` the store alone.
///
/// The tests are synchronous on purpose: they pump the main run loop
/// (`drainUntil`), which an `async` test body — itself a job on the main
/// queue — can't, so the store's main-actor work would never run.
@MainActor
final class SessionTabLiveTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private var scratch: URL!
    private var stage: AppKitStage?
    private var store: SessionStore?
    private let recorder = TabRecorder()

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        stage?.teardown()
        await store?.endAll()
        try? FileManager.default.removeItem(at: scratch)
    }

    private var folder: URL { scratch.appendingPathComponent("work", isDirectory: true) }

    /// A launcher that waits — the CLI still *Starting* — `delay` seconds on a
    /// first launch and `resumeDelay` on a resume, then becomes the fake CLI.
    private func fakeCLI(delay: TimeInterval, resumeDelay: TimeInterval) throws -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSDK/Tests/AgentSDKTests/Fixtures/fake_cli.py")
        let launcher = scratch.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            case "$*" in
                *--resume*) sleep \(resumeDelay) ;;
                *) sleep \(delay) ;;
            esac
            exec /usr/bin/env python3 '\(fixture.path)' "$@"
            """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher.path
    }

    /// A New tab in `folder` over a store launching the fake CLI.
    private func mountDraft(
        launchDelay: TimeInterval = 0, resumeDelay: TimeInterval = 0
    ) throws -> SessionTabViewController {
        let launcher = try fakeCLI(delay: launchDelay, resumeDelay: resumeDelay)
        let launch = CLIConfiguration(binaryPath: launcher, inheritsParentEnvironment: true)
        let store = SessionStore(
            launch: { _ in launch },
            directories: Just(SessionDirectory(url: scratch.appendingPathComponent("projects"))).eraseToAnyPublisher(),
            catalog: Just(Fixture.catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            branches: BranchService(), read: { _ in Transcript(messages: []) })
        self.store = store
        let context = TranscriptTab.Context(
            sessions: store,
            catalog: Just(Fixture.catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: "ccterm-tests-\(UUID().uuidString)")!),
            branches: BranchService(),
            recentFolders: Just([]).eraseToAnyPublisher())
        let tab = SessionTabViewController(
            .draft(folder: folder, text: ""), title: SessionTabTitle.draft, context: context)
        tab.tabDelegate = recorder
        stage = AppKitStage.mount(tab, size: CGSize(width: 900, height: 700))
        tab.viewDidAppear()
        stage!.drain()
        return tab
    }

    private func composer(of tab: SessionTabViewController) throws -> ComposerViewController {
        try XCTUnwrap(tab.children.compactMap { $0 as? ComposerViewController }.first)
    }

    /// Presses Send with `text`, as the composer reports it.
    private func send(_ text: String, in tab: SessionTabViewController) throws {
        let composer = try composer(of: tab)
        composer.text = ""
        tab.composerViewController(composer, didSubmit: text)
    }

    /// The user's bubbles the tab's transcript shows, in order.
    private func bubbles(in tab: SessionTabViewController) -> [TranscriptRowContent.UserMessage] {
        guard let transcript = tab.children.compactMap({ $0 as? TranscriptViewController }).first,
            let view = stage?.find(TranscriptView.self)
        else { return [] }
        return (0..<transcript.numberOfRows(in: view)).compactMap {
            guard case .userMessage(let message) = transcript.transcriptView(view, rowAt: $0).content else {
                return nil
            }
            return message
        }
    }

    // MARK: - Send

    func testSendBecomesTheSessionsTabShowingTheHeldPromptThenItsAnswer() throws {
        let tab = try mountDraft(launchDelay: 3)
        try send("echo", in: tab)

        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil }, "the tab never became the session's")
        XCTAssertEqual(recorder.started, [try XCTUnwrap(tab.transcriptURL)])
        XCTAssertFalse(tab.children.contains { $0 is NewSessionViewController })

        // While the CLI starts, the prompt is a bubble at half strength.
        XCTAssertTrue(
            stage!.drainUntil(timeout: 3) { self.bubbles(in: tab).map(\.isPending) == [true] },
            "no held bubble: \(bubbles(in: tab))")
        XCTAssertEqual(bubbles(in: tab).map(\.text), ["echo"])

        // The CLI takes it: the replay confirms the bubble in place.
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) { self.bubbles(in: tab).map(\.isPending) == [false] },
            "the prompt was never confirmed: \(bubbles(in: tab))")
        XCTAssertEqual(bubbles(in: tab).map(\.text), ["echo"])
        XCTAssertEqual(recorder.returnedToDraft, 0)
    }

    // MARK: - Stop while Starting

    func testStopWhileStartingGivesTheWordsBackToTheNewTab() throws {
        let tab = try mountDraft(launchDelay: 5)
        try send("echo", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        let url = try XCTUnwrap(tab.transcriptURL)
        XCTAssertEqual(store?.activities[url], .responding, "starting")

        tab.composerViewControllerDidRequestStop(try composer(of: tab))

        XCTAssertNil(tab.transcriptURL)
        XCTAssertEqual(recorder.returnedToDraft, 1)
        XCTAssertEqual(try composer(of: tab).text, "echo")
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController })
        XCTAssertFalse(tab.children.contains { $0 is TranscriptViewController })
        XCTAssertEqual(store?.activities[url], nil, "the launch is gone")
    }

    func testAfterStoppingTheSameWordsCanBeSentAgain() throws {
        let tab = try mountDraft(launchDelay: 5)
        try send("echo", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        tab.composerViewControllerDidRequestStop(try composer(of: tab))
        XCTAssertNil(tab.transcriptURL)

        try send("echo", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        XCTAssertEqual(recorder.started.count, 2)
        XCTAssertNotEqual(recorder.started[0], recorder.started[1], "a new session, not the cancelled one")
    }

    func testStopWhileARestartStartsKeepsTheConversation() throws {
        let tab = try mountDraft(resumeDelay: 5)
        try send("echo", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        let url = try XCTUnwrap(tab.transcriptURL)
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) {
                self.bubbles(in: tab).map(\.isPending) == [false] && self.store?.activities[url] == .idle
            }, "the first turn never ended")

        // Another account's model restarts the CLI: *Starting* again.
        store?.update(.model(Fixture.choice("haiku", on: Fixture.relay)), at: url)
        XCTAssertEqual(store?.activities[url], .responding)
        stage!.drain(seconds: 0.3)

        tab.composerViewControllerDidRequestStop(try composer(of: tab))

        XCTAssertEqual(tab.transcriptURL, url, "the tab is still the session's")
        XCTAssertEqual(recorder.returnedToDraft, 0)
        XCTAssertTrue(tab.children.contains { $0 is TranscriptViewController })
        XCTAssertFalse(tab.children.contains { $0 is NewSessionViewController })
        XCTAssertEqual(bubbles(in: tab).map(\.text), ["echo"], "the conversation stays")

        // The session is at rest on the new choice, and the next prompt resumes it.
        XCTAssertTrue(stage!.drainUntil(timeout: 2) { self.store?.activities[url] == nil }, "not at rest")
        try send("echo", in: tab)
        XCTAssertEqual(store?.activities[url], .responding, "resuming")
    }

    // MARK: - Another account

    /// A conversation answered and idle, ready to switch accounts.
    private func idleSession() throws -> (SessionTabViewController, URL) {
        let tab = try mountDraft()
        try send("echo", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        let url = try XCTUnwrap(tab.transcriptURL)
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) {
                self.bubbles(in: tab).map(\.isPending) == [false] && self.store?.activities[url] == .idle
            }, "the first turn never ended")
        return (tab, url)
    }

    func testAnotherAccountsModelAsksFirstThenRestarts() throws {
        let (tab, url) = try idleSession()
        tab.composerViewController(
            try composer(of: tab), didChoose: ComposerModel.id(of: .model(Fixture.choice("haiku", on: Fixture.relay))))

        let window = try XCTUnwrap(tab.view.window)
        XCTAssertTrue(stage!.drainUntil(timeout: 2) { window.attachedSheet != nil }, "no confirmation sheet")
        XCTAssertEqual(store?.activities[url], .idle, "nothing restarts before the reader says so")

        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)

        XCTAssertTrue(stage!.drainUntil(timeout: 2) { self.store?.activities[url] == .responding }, "no restart")
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) { self.store?.activities[url] == .idle }, "the restart never settled")
        XCTAssertEqual(tab.transcriptURL, url)
        XCTAssertEqual(bubbles(in: tab).map(\.text), ["echo"])
    }

    func testCancellingTheRestartSheetChangesNothing() throws {
        let (tab, url) = try idleSession()
        tab.composerViewController(
            try composer(of: tab), didChoose: ComposerModel.id(of: .model(Fixture.choice("haiku", on: Fixture.relay))))
        let window = try XCTUnwrap(tab.view.window)
        XCTAssertTrue(stage!.drainUntil(timeout: 2) { window.attachedSheet != nil }, "no confirmation sheet")

        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        stage!.drain(seconds: 0.5)

        XCTAssertEqual(store?.activities[url], .idle)
        XCTAssertNil(window.attachedSheet)
    }

    func testStopDuringTheRiseCancelsTheLaunchAndStaysTheNewTab() throws {
        let tab = try mountDraft(launchDelay: 5)
        try send("echo", in: tab)
        // Still rising: the tab is not the session's yet.
        XCTAssertNil(tab.transcriptURL)
        XCTAssertEqual(store?.activities.count, 1, "starting")

        tab.composerViewControllerDidRequestStop(try composer(of: tab))

        XCTAssertEqual(store?.activities.isEmpty, true, "the launch is gone")
        stage!.drain(seconds: 1)
        XCTAssertNil(tab.transcriptURL, "the rise's end did nothing")
        XCTAssertEqual(recorder.started, [])
        XCTAssertEqual(recorder.returnedToDraft, 0)
        XCTAssertEqual(try composer(of: tab).text, "echo")
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController })
    }

    // MARK: - Failure

    func testACrashShowsItsLogBeside() throws {
        let tab = try mountDraft()
        try send("crash", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        let url = try XCTUnwrap(tab.transcriptURL)
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) {
                if case .failed? = self.store?.activities[url] { return true }
                return false
            }, "the CLI never failed")
        stage!.drain(seconds: 0.3)

        tab.composerViewControllerDidRequestLog(try composer(of: tab))

        XCTAssertEqual(recorder.opened.count, 1, "the log opens beside")
        guard case .document? = recorder.opened.first else { return XCTFail("not a document: \(recorder.opened)") }
    }

    // MARK: - Queued

    func testAPromptSentWhileClaudeWorksIsQueuedUnderTheFirst() throws {
        let tab = try mountDraft()
        try send("hold", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })
        XCTAssertTrue(
            stage!.drainUntil(timeout: 15) { self.bubbles(in: tab).map(\.isPending) == [false] },
            "the first prompt was never taken")
        let url = try XCTUnwrap(tab.transcriptURL)
        XCTAssertEqual(store?.activities[url], .responding, "the `hold` turn runs until it is answered")

        try send("hold", in: tab)

        XCTAssertTrue(
            stage!.drainUntil(timeout: 10) { self.bubbles(in: tab).map(\.isPending) == [false, true] },
            "no queued bubble: \(bubbles(in: tab))")
        XCTAssertEqual(try composer(of: tab).text, "", "the words left the field for the bubble")
    }
}
