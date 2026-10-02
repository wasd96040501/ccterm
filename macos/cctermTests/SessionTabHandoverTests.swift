import AgentSDK
import AppKit
import Combine
import TranscriptKit
import XCTest

@testable import ccterm

/// Send in a New tab, in the order the tab documents: the session starts at
/// once, the page rises, the composer's place is captured, the window is told
/// before anything swaps, then the New view goes, the transcript comes and the
/// composer glides down from where it stood.
///
/// The CLI's own part — the held prompt, *Starting*, Stop taking the words back
/// — is the store's (`SessionStoreTests`); here the store only reads, so a
/// started session is a URL and nothing launches.
@MainActor
final class SessionTabHandoverTests: XCTestCase {
    private var stage: AppKitStage?
    private let recorder = TabRecorder()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        stage?.teardown()
    }

    private func mountDraft(folder: URL? = URL(fileURLWithPath: "/tmp/repo")) -> SessionTabViewController {
        let context = TranscriptTab.Context.reading()
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

    /// Types `text` and presses Send, as the composer reports it: the field is
    /// cleared before the tab hears.
    private func send(_ text: String, in tab: SessionTabViewController) throws {
        let composer = try composer(of: tab)
        composer.text = ""
        tab.composerViewController(composer, didSubmit: text)
    }

    private func windowFrame(of composer: ComposerViewController) -> NSRect {
        composer.view.convert(composer.view.bounds, to: nil)
    }

    // MARK: - The order

    func testTheWindowIsToldBeforeTheNewViewGoesAndTheTranscriptComesAfter() throws {
        let tab = mountDraft()
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController }, "premise: it is a New tab")

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { self.recorder.started.count == 1 }, "the window was never told")

        let children = try XCTUnwrap(recorder.childrenAtStart.first)
        XCTAssertTrue(
            children.contains("NewSessionViewController"),
            "the New view had gone when the window was told: \(children)")
        XCTAssertFalse(children.contains("TranscriptViewController"), "the transcript came before the window was told")
        XCTAssertEqual(tab.transcriptURL, recorder.started[0])
        XCTAssertEqual(recorder.started[0].pathExtension, "jsonl")

        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.children.contains { $0 is TranscriptViewController } })
        XCTAssertFalse(tab.children.contains { $0 is NewSessionViewController }, "the New view stayed")
        XCTAssertEqual(recorder.started.count, 1, "the window was told twice")
        XCTAssertNil(tab.draftText, "it is a session's tab now")
    }

    /// The session is real from the first moment: the tab is its session's
    /// before the CLI has written a line.
    func testTheTabIsTheSessionsAtOnce() throws {
        let tab = mountDraft()

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.transcriptURL, recorder.started.first)
        XCTAssertFalse(tab.isUntouchedDraft)
    }

    func testTheTabIsNamedForThePromptsFirstLine() throws {
        let tab = mountDraft()

        try send("Fix the gutter overflow\nand then the margin", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.title, "Fix the gutter overflow")
    }

    func testALongPromptIsCutAtFortyCharactersInTheTitle() throws {
        let tab = mountDraft()
        let long = String(repeating: "word ", count: 20)

        try send(long, in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.transcriptURL != nil })

        XCTAssertEqual(tab.title, SessionTabTitle.fromPrompt(long))
        XCTAssertLessThanOrEqual(try XCTUnwrap(tab.title).count, 41)
    }

    /// Nothing to launch in: the words stay in the field, and the tab stays a
    /// New tab.
    func testSendWithoutAFolderKeepsTheWordsAndStaysANewTab() throws {
        let tab = mountDraft(folder: nil)

        try send("Fix the gutter", in: tab)
        stage!.drain(seconds: 0.2)

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertNil(tab.transcriptURL)
        XCTAssertEqual(try composer(of: tab).text, "Fix the gutter")
        XCTAssertTrue(tab.children.contains { $0 is NewSessionViewController })
    }

    // MARK: - Geometry

    /// Nothing jumps: right after the swap the composer is where it stood in the
    /// New view, not at the bottom; the transcript is the whole tab.
    func testTheComposerStartsTheGlideWhereItStood() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()
        let before = windowFrame(of: composer)
        XCTAssertGreaterThan(before.height, 20, "premise: the composer was laid out")

        try send("Fix the gutter", in: tab)
        XCTAssertTrue(stage!.drainUntil(timeout: 5) { tab.children.contains { $0 is TranscriptViewController } })
        let after = windowFrame(of: composer)

        let rest = tab.view.convert(tab.view.bounds, to: nil).minY + 16
        XCTAssertGreaterThan(
            abs(before.minY - rest), 40, "premise: the New view's composer is not already at the bottom")
        XCTAssertEqual(after.minY, before.minY, accuracy: 40, "the composer jumped at the swap")
        XCTAssertEqual(after.width, before.width, accuracy: 4)
        let transcript = try XCTUnwrap(stage!.find(TranscriptView.self))
        XCTAssertEqual(tab.view.convert(transcript.bounds, from: transcript), tab.view.bounds)
    }

    /// Needs the display awake: the glide advances on display refreshes.
    func testTheComposerEndsFloatingSixteenAboveTheBottomAtSevenTwenty() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()

        try send("Fix the gutter", in: tab)

        XCTAssertTrue(
            stage!.drainUntil(timeout: 5) {
                abs(composer.view.convert(composer.view.bounds, to: tab.view).minY - 16) < 0.5
            }, "the composer never reached its place (is the display asleep?)")
        let card = composer.view.convert(composer.view.bounds, to: tab.view)
        XCTAssertEqual(card.width, 720, accuracy: 0.5)
        XCTAssertEqual(card.midX, tab.view.bounds.midX, accuracy: 0.5)
    }

    /// Needs the display awake: samples the glide's frames. Every frame stays
    /// between where it started and where it ends, and the card ends at rest.
    func testTheGlideMovesMonotonicallyDownward() throws {
        let tab = mountDraft()
        let composer = try composer(of: tab)
        tab.view.layoutSubtreeIfNeeded()
        let start = composer.view.convert(composer.view.bounds, to: tab.view).minY

        try send("Fix the gutter", in: tab)
        var samples: [CGFloat] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 120))
            samples.append(composer.view.convert(composer.view.bounds, to: tab.view).minY)
            if let last = samples.last, abs(last - 16) < 0.5, samples.count > 5 { break }
        }

        XCTAssertGreaterThan(samples.count, 5, "the glide produced no frames (is the display asleep?)")
        XCTAssertEqual(try XCTUnwrap(samples.last), 16, accuracy: 0.5)
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(later, earlier + 0.5, "the composer went back up mid-glide")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(samples.first), start + 0.5)
    }
}
